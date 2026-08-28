-- A monthly beat — "what changed this month" — and the day of the month it
-- lands on.
--
-- Capped at 28 rather than 31: a beat set for the 30th would silently skip
-- February, and a schedule that quietly misses a month is worse than one that
-- runs three days early.
alter table public.beats
    add column day_of_month smallint not null default 1 check (day_of_month between 1 and 28);

alter table public.beats drop constraint beats_cadence_check;
alter table public.beats add constraint beats_cadence_check
    check (cadence in ('daily', 'weekdays', 'weekly', 'monthly'));

-- The six-argument form stays, delegating to this one. A released client that
-- calls it keeps working — see `.agents/rules/backward-compatibility.md`.
create or replace function public.next_beat_run(
    p_cadence text,
    p_hour smallint,
    p_minute smallint,
    p_weekday smallint,
    p_timezone text,
    p_after timestamptz,
    p_day_of_month smallint
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
    v_day   smallint := least(greatest(coalesce(p_day_of_month, 1), 1), 28);
begin
    v_local := timezone(v_zone, p_after);

    if p_cadence = 'monthly' then
        v_next := date_trunc('month', v_local)
                + make_interval(days => v_day - 1, hours => p_hour, mins => p_minute);
        if v_next <= v_local then
            v_next := date_trunc('month', v_local) + interval '1 month'
                    + make_interval(days => v_day - 1, hours => p_hour, mins => p_minute);
        end if;
        return timezone(v_zone, v_next);
    end if;

    v_next := date_trunc('day', v_local) + make_interval(hours => p_hour, mins => p_minute);
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

create or replace function public.next_beat_run(
    p_cadence text,
    p_hour smallint,
    p_minute smallint,
    p_weekday smallint,
    p_timezone text,
    p_after timestamptz
)
returns timestamptz
language sql
stable
set search_path = ''
as $$
    select public.next_beat_run(p_cadence, p_hour, p_minute, p_weekday, p_timezone, p_after, 1::smallint);
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
    if tg_op = 'INSERT'
       or not old.enabled
       or (old.cadence, old.hour, old.minute, old.weekday, old.timezone, old.day_of_month)
          is distinct from (new.cadence, new.hour, new.minute, new.weekday, new.timezone, new.day_of_month)
    then
        new.next_run_at := public.next_beat_run(
            new.cadence, new.hour, new.minute, new.weekday, new.timezone, now(), new.day_of_month
        );
    end if;
    return new;
end;
$$;

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
               cadence, hour, minute, weekday, timezone, day_of_month
          from public.beats
         where enabled and next_run_at is not null and next_run_at <= now()
         for update skip locked
    ),
    queued as (
        insert into public.beat_runs (beat_id, user_id, scheduled_for)
        select id, user_id, next_run_at from due
         where next_run_at > now() - interval '6 hours'
        on conflict (beat_id, scheduled_for) do nothing
        returning 1
    ),
    advanced as (
        update public.beats b
           set next_run_at = public.next_beat_run(
                   d.cadence, d.hour, d.minute, d.weekday, d.timezone,
                   greatest(d.next_run_at, now() - interval '6 hours'),
                   d.day_of_month
               )
          from due d
         where b.id = d.id
        returning 1
    )
    select count(*) into v_enqueued from queued;

    update public.beat_runs
       set status = 'expired', finished_at = now()
     where status = 'due' and scheduled_for < now() - interval '6 hours';

    return v_enqueued;
end;
$$;

revoke all on function public.next_beat_run(text, smallint, smallint, smallint, text, timestamptz, smallint) from public, anon;
grant execute on function public.next_beat_run(text, smallint, smallint, smallint, text, timestamptz, smallint) to authenticated;
