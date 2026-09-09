-- Beats: a saved question that asks itself on a schedule.
--
-- The agent loop — query prep, retrieval, the screen record, tool calls, the
-- confirmation gate on anything that writes — lives in the macOS client, in
-- `KnowledgeChatStore`. Reimplementing it in Deno so a cron job could run it
-- would mean two implementations of the one thing whose answers people trust,
-- drifting apart from the day they shipped. So the schedule lives here and the
-- work does not: cron only decides that a run is *due*, and the desktop claims
-- it and answers it through the same pipeline a typed question goes through.
--
-- The cost of that choice is honest: a Mac that never wakes never runs its
-- beats. `enqueue_due_beats` expires a run nobody claimed rather than letting
-- five of yesterday's briefings arrive at once on Monday morning.

create table public.beats (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    -- What the user called it. Shown in the list and used as the thread title,
    -- so an answer is findable by the name of the thing that asked for it.
    title       text        not null,
    -- The question itself, in the user's own words. This is a chat prompt, not
    -- a template with slots: whatever a person can type into Ask Nod, a beat
    -- can hold.
    prompt      text        not null,
    cadence     text        not null check (cadence in ('daily', 'weekdays', 'weekly')),
    -- Local wall-clock time the user picked, in `timezone`. Stored apart from
    -- `next_run_at` because "every morning at 9" survives a flight and a DST
    -- change; a stored UTC instant does not.
    hour        smallint    not null default 9  check (hour between 0 and 23),
    minute      smallint    not null default 0  check (minute between 0 and 59),
    -- ISO weekday, Monday = 1. Only read for the weekly cadence.
    weekday     smallint    not null default 1  check (weekday between 1 and 7),
    timezone    text        not null default 'UTC',
    enabled     boolean     not null default true,
    -- Maintained by `beats_set_next_run`, never by a client. One owner for the
    -- schedule arithmetic means the list, the cron job and the Mac cannot
    -- disagree about when a beat runs next.
    next_run_at timestamptz,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index beats_user_idx on public.beats (user_id, created_at desc);
create index beats_due_idx  on public.beats (next_run_at) where enabled;

create table public.beat_runs (
    id            uuid        primary key default gen_random_uuid(),
    beat_id       uuid        not null references public.beats(id) on delete cascade,
    user_id       uuid        not null references auth.users(id) on delete cascade,
    -- The instant the beat was due, not the instant it ran. A briefing claimed
    -- at 10:40 because the Mac was shut is still Friday's 09:00 briefing, and
    -- the answer says so.
    scheduled_for timestamptz not null,
    status        text        not null default 'due'
                  check (status in ('due', 'claimed', 'done', 'failed', 'expired')),
    claimed_at    timestamptz,
    finished_at   timestamptz,
    -- The thread the answer was written into. Null until the run finishes, and
    -- on delete of that thread the run keeps its row and loses its link.
    thread_id     uuid        references public.knowledge_threads(id) on delete set null,
    -- Why a failed run failed, in the words the card will show.
    error         text,
    created_at    timestamptz not null default now()
);

-- One run per beat per due instant. A cron tick that overlaps the previous one
-- must not enqueue the same 09:00 briefing twice.
create unique index beat_runs_slot_idx on public.beat_runs (beat_id, scheduled_for);
create index beat_runs_claimable_idx on public.beat_runs (user_id, status, scheduled_for);

-- The next wall-clock occurrence of `hour:minute` in the beat's own timezone,
-- as an instant. Pure, so the schedule can be reasoned about — and tested —
-- without waiting a day for it.
create or replace function public.next_beat_run(
    p_cadence text,
    p_hour smallint,
    p_minute smallint,
    p_weekday smallint,
    p_timezone text,
    p_after timestamptz
)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
    v_zone  text := coalesce(nullif(p_timezone, ''), 'UTC');
    v_local timestamp;
    v_next  timestamp;
begin
    -- Arithmetic in the user's own wall clock, converted back at the end: an
    -- hour added to a UTC instant lands in the wrong hour twice a year.
    v_local := timezone(v_zone, p_after);
    v_next  := date_trunc('day', v_local) + make_interval(hours => p_hour, mins => p_minute);
    if v_next <= v_local then
        v_next := v_next + interval '1 day';
    end if;

    if p_cadence = 'weekdays' then
        while extract(isodow from v_next) > 5 loop
            v_next := v_next + interval '1 day';
        end loop;
    elsif p_cadence = 'weekly' then
        while extract(isodow from v_next) <> p_weekday loop
            v_next := v_next + interval '1 day';
        end loop;
    end if;

    return timezone(v_zone, v_next);
end;
$$;

create or replace function public.beats_set_next_run()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    if not new.enabled then
        new.next_run_at := null;
        return new;
    end if;
    -- Recomputed only when the schedule itself moved. Renaming a beat, or
    -- editing its prompt, must not push this morning's run into tomorrow.
    if tg_op = 'INSERT'
       or not old.enabled
       or (old.cadence, old.hour, old.minute, old.weekday, old.timezone)
          is distinct from (new.cadence, new.hour, new.minute, new.weekday, new.timezone)
    then
        new.next_run_at := public.next_beat_run(
            new.cadence, new.hour, new.minute, new.weekday, new.timezone, now()
        );
    end if;
    return new;
end;
$$;

create trigger beats_set_next_run
    before insert or update on public.beats
    for each row execute function public.beats_set_next_run();

-- The cron tick. Enqueues what is due, advances the beat, and closes out what
-- nobody was awake to answer.
create or replace function public.enqueue_due_beats()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_enqueued integer;
begin
    with due as (
        select id, user_id, next_run_at,
               cadence, hour, minute, weekday, timezone
          from public.beats
         where enabled and next_run_at is not null and next_run_at <= now()
         for update skip locked
    ),
    queued as (
        insert into public.beat_runs (beat_id, user_id, scheduled_for)
        select id, user_id, next_run_at from due
        -- A slot already past the claim window is not enqueued at all. A Mac
        -- shut for a fortnight otherwise came back to a fortnight of runs,
        -- every one of them expiring the moment it was written.
         where next_run_at > now() - interval '6 hours'
        on conflict (beat_id, scheduled_for) do nothing
        returning 1
    ),
    advanced as (
        update public.beats b
           set next_run_at = public.next_beat_run(
                   d.cadence, d.hour, d.minute, d.weekday, d.timezone,
                   greatest(d.next_run_at, now() - interval '6 hours')
               )
          from due d
         where b.id = d.id
        returning 1
    )
    select count(*) into v_enqueued from queued;

    -- A run nobody claimed is not owed forever. Six hours is long enough to
    -- cover a late start and short enough that a Mac opened on Monday doesn't
    -- deliver Friday's morning briefing as if it were news.
    update public.beat_runs
       set status = 'expired', finished_at = now()
     where status = 'due' and scheduled_for < now() - interval '6 hours';

    return v_enqueued;
end;
$$;

-- Two Macs on one account both see the same due run. This is what decides
-- which of them answers it: the claim is the update, so the loser gets no row
-- back and does nothing.
-- `setof` rather than a single composite on purpose: a plpgsql function that
-- returns an unassigned record hands PostgREST a row of nulls, which reads to a
-- client exactly like a claim that succeeded. An empty set cannot be misread.
create or replace function public.claim_beat_run(p_run_id uuid)
returns setof public.beat_runs
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    return query
        update public.beat_runs
           set status = 'claimed', claimed_at = now()
         where id = p_run_id and user_id = auth.uid() and status = 'due'
        returning *;
end;
$$;

-- A beat's answer is an ordinary thread — that is the whole point, because it
-- means the user can reply to it and keep going. It is stamped so the Ask Nod
-- list can leave it out: a person who reads three beats a day should not have
-- to scroll past ninety of them to find the conversation they had.
alter table public.knowledge_threads
    add column beat_id uuid references public.beats(id) on delete set null;

create index knowledge_threads_beat_idx
    on public.knowledge_threads (beat_id) where beat_id is not null;

alter table public.beats enable row level security;
alter table public.beat_runs enable row level security;

create policy "users read own beats"
    on public.beats for select to authenticated
    using (auth.uid() = user_id);

create policy "users insert own beats"
    on public.beats for insert to authenticated
    with check (auth.uid() = user_id);

create policy "users update own beats"
    on public.beats for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own beats"
    on public.beats for delete to authenticated
    using (auth.uid() = user_id);

create policy "users read own beat runs"
    on public.beat_runs for select to authenticated
    using (auth.uid() = user_id);

-- The client finishes a run it claimed: `done` with a thread, or `failed` with
-- a reason. Insert stays closed — a run exists because a schedule came due,
-- never because a client said so.
create policy "users update own beat runs"
    on public.beat_runs for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own beat runs"
    on public.beat_runs for delete to authenticated
    using (auth.uid() = user_id);

-- Nothing is granted by default since `20260805082210`, so every callable
-- surface is named here.
grant execute on function public.next_beat_run(text, smallint, smallint, smallint, text, timestamptz) to authenticated;
grant execute on function public.claim_beat_run(uuid) to authenticated;
revoke all on function public.enqueue_due_beats() from public, anon, authenticated;
grant execute on function public.enqueue_due_beats() to service_role;

select cron.schedule(
    'enqueue-due-beats',
    '* * * * *',
    $$select public.enqueue_due_beats()$$
);
