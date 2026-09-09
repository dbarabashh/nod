-- A voice in a recording, and how sure we are whose it is.
--
-- `meetings.speaker_names` (`20260730151505`) holds `{"1": "Andy"}` — a name,
-- with no way to say where it came from or how much to trust it. That is enough
-- to label a transcript and not enough to act: filing work against Andy needs
-- Andy's identifier, and needs to know the difference between "the user told us"
-- and "a model guessed from context".
--
-- `speaker_names` is deliberately left alone. It is what every shipped build
-- reads to draw the chips above a transcript, and a client that has not updated
-- must keep rendering exactly what it renders today. This table is written
-- beside it, not instead of it, and `confirm_speaker` below writes both — so the
-- correction a user makes lands in the structured record *and* in the string the
-- old UI reads.
--
-- Confidence does not gate display, on purpose. Today an LLM-named cluster shows
-- its name, and introducing a threshold here would make names silently vanish
-- from meetings that already have them. What confidence gates is *acting*: an
-- owner resolved at 0.6 is not somebody to assign a ticket to, which is the
-- question `action_proposals` will ask and the transcript never does.

create table public.meeting_speakers (
    meeting_id   uuid        not null references public.meetings(id) on delete cascade,
    -- The diarized cluster number, as it appears in `meeting_transcripts.speaker`.
    cluster      integer     not null,
    -- Null until somebody is actually identified. A named cluster with no person
    -- behind it is the normal case outside an organization.
    person_id    uuid        references public.people(id) on delete set null,
    -- What to show. Kept even when `person_id` is set, so a transcript still
    -- reads correctly if the person is later removed.
    display_name text,
    confidence   numeric(3, 2) not null check (confidence between 0 and 1),
    -- Which signal decided it, in the order the finalize actually tries them.
    -- `microphone` is the local speaker and is the only one that is certain
    -- without anybody confirming anything.
    decided_by   text        not null check (decided_by in ('microphone', 'roster', 'llm', 'elimination', 'user')),
    decided_at   timestamptz not null default now(),
    primary key (meeting_id, cluster)
);

create index meeting_speakers_person_idx
    on public.meeting_speakers (person_id) where person_id is not null;

alter table public.meeting_speakers enable row level security;

-- Whoever can read the meeting can read who spoke in it.
--
-- Expressed as a subquery against `meetings` rather than by restating the rules,
-- because there are four ways to reach a meeting today — owning it, a shared
-- folder, a direct grant, an administrator overlay — and a fifth will not think
-- to update a copy here. Row-level security applies inside this subquery, so the
-- answer is by construction the same one `meetings` would give.
create policy "readers of a meeting read its speakers"
    on public.meeting_speakers for select to authenticated
    using (exists (
        select 1 from public.meetings m where m.id = meeting_id
    ));

-- Written by the person who recorded it, like the transcript itself. Speaker
-- labels are part of a recording, not a shared decision: two people relabelling
-- one meeting is a conflict this model does not have anywhere else.
create policy "owners write their meeting speakers"
    on public.meeting_speakers for insert to authenticated
    with check (exists (
        select 1 from public.meetings m where m.id = meeting_id and m.user_id = (select auth.uid())
    ));

create policy "owners update their meeting speakers"
    on public.meeting_speakers for update to authenticated
    using (exists (
        select 1 from public.meetings m where m.id = meeting_id and m.user_id = (select auth.uid())
    ));

create policy "owners delete their meeting speakers"
    on public.meeting_speakers for delete to authenticated
    using (exists (
        select 1 from public.meetings m where m.id = meeting_id and m.user_id = (select auth.uid())
    ));

grant select, insert, update, delete on table public.meeting_speakers to authenticated;

-- ── The correction ──────────────────────────────────────────────────────────
--
-- The user answering "who was that" is the strongest signal there is, and the
-- only one that can attach a person rather than a name.
--
-- A function rather than a plain update because two rows have to move together:
-- the structured record here, and the `speaker_names` string the transcript view
-- reads. Left to the client they would drift the first time one write failed.
create function public.confirm_speaker(
    p_meeting uuid,
    p_cluster integer,
    p_person  uuid default null,
    p_name    text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org  uuid;
    v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_cluster is null or p_cluster < 1 then
        raise exception 'a speaker cluster is required' using errcode = '22023';
    end if;

    select m.org_id into v_org
      from public.meetings m
     where m.id = p_meeting and m.user_id = auth.uid() and m.deleted_at is null;
    if not found then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;

    -- A person from another organization would be a name this account is not
    -- entitled to write down, let alone assign work to.
    if p_person is not null then
        if v_org is null or not exists (
            select 1 from public.people pe
             where pe.id = p_person and pe.org_id = v_org and pe.deleted_at is null
        ) then
            raise exception 'that person is not in this meeting''s organization' using errcode = '42501';
        end if;
        select coalesce(v_name, pe.display_name, pe.primary_email) into v_name
          from public.people pe where pe.id = p_person;
    end if;

    insert into public.meeting_speakers (meeting_id, cluster, person_id, display_name, confidence, decided_by)
    values (p_meeting, p_cluster, p_person, v_name, 1.0, 'user')
    on conflict (meeting_id, cluster) do update
       set person_id    = excluded.person_id,
           display_name = excluded.display_name,
           confidence   = excluded.confidence,
           decided_by   = excluded.decided_by,
           decided_at   = now();

    -- The string the transcript view already reads. Removing a name clears the
    -- key rather than writing an empty one, because the renderer falls back to
    -- "Speaker 2" on absence and would print a blank chip on "".
    update public.meetings
       set speaker_names = case
               when v_name is null then coalesce(speaker_names, '{}'::jsonb) - p_cluster::text
               else coalesce(speaker_names, '{}'::jsonb) || jsonb_build_object(p_cluster::text, v_name)
           end
     where id = p_meeting;
end;
$$;

revoke all on function public.confirm_speaker(uuid, integer, uuid, text) from public, anon;
grant execute on function public.confirm_speaker(uuid, integer, uuid, text) to authenticated;

-- ── What is already on record ───────────────────────────────────────────────
--
-- Every name a past meeting carries came from the naming pass, so that is what
-- it is recorded as. `llm` at 0.6 is not a measurement of those specific
-- meetings — it is the standing confidence of the signal that produced them,
-- and it is deliberately below anything that may be assigned work without a
-- person confirming it first.
insert into public.meeting_speakers (meeting_id, cluster, display_name, confidence, decided_by, decided_at)
select m.id, (entry.key)::integer, entry.value, 0.6, 'llm', coalesce(m.ended_at, m.started_at)
  from public.meetings m
  cross join lateral jsonb_each_text(m.speaker_names) as entry
 where m.speaker_names is not null
   and entry.key ~ '^[0-9]+$'
   and (entry.key)::integer >= 1
   and nullif(btrim(entry.value), '') is not null
on conflict (meeting_id, cluster) do nothing;
