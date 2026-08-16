-- A live room must not disappear because nobody happened to be talking.
--
-- `_live_lease_in_org` treats a lease as live for 90 seconds after
-- `coalesce(last_used_at, granted_at)`, and the only thing that moved
-- `last_used_at` was `validate_meeting_lease`, called from the proxy when a
-- transcribe chunk arrives — and throttled to once a minute on top. Chunks are
-- produced by voice activity detection, so they exist only while somebody
-- speaks. Thirty seconds of quiet is all it takes for the margin between the
-- throttle and the window to run out, and a colleague opening their Mac during
-- a pause is told nobody is recording.
--
-- Silence is the normal state of a meeting: someone is presenting, reading, or
-- thinking. Liveness is a property of the recording, not of the audio.
--
-- So the client says so directly, on its own clock. Unthrottled on purpose —
-- the write is one row by primary key, and the point is that it lands.

create or replace function public.touch_meeting_lease(p_meeting uuid)
    returns boolean
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user uuid := auth.uid();
    v_touched integer;
begin
    if v_user is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    -- Own, active leases only. A heartbeat is a statement about a recording the
    -- caller is making; it can neither revive somebody else's nor resurrect one
    -- that has already ended.
    update public.meeting_start_leases
       set last_used_at = now()
     where meeting_id = p_meeting
       and user_id = v_user
       and status = 'active'
       and expires_at > now();

    get diagnostics v_touched = row_count;
    return v_touched > 0;
end;
$$;

revoke all on function public.touch_meeting_lease(uuid) from public, anon;
grant execute on function public.touch_meeting_lease(uuid) to authenticated;
