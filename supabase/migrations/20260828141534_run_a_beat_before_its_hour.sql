-- "Run now" — the button that makes a beat answerable without waiting for its
-- hour. It enqueues a run exactly as the cron tick would; the Mac claims and
-- answers it the same way, so there is one execution path and not two.
--
-- `security definer` because inserting into `beat_runs` is closed to clients on
-- purpose: a run exists because a schedule came due, or because the owner of
-- the beat asked for one here. Both are checked below.
create or replace function public.run_beat_now(p_beat_id uuid)
returns setof public.beat_runs
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_owner uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    select user_id into v_owner from public.beats where id = p_beat_id;
    if v_owner is null or v_owner <> auth.uid() then
        raise exception 'no such beat';
    end if;
    -- A second press inside the same second returns the run already queued
    -- rather than a duplicate, and a run still waiting to be claimed is
    -- returned untouched.
    return query
        insert into public.beat_runs (beat_id, user_id, scheduled_for)
        values (p_beat_id, v_owner, date_trunc('second', now()))
        on conflict (beat_id, scheduled_for) do update set status = public.beat_runs.status
        returning *;
end;
$$;

revoke all on function public.run_beat_now(uuid) from public, anon;
grant execute on function public.run_beat_now(uuid) to authenticated;
