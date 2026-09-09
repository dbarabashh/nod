-- Discovery stops naming the host to somebody who has not shown they belong.
--
-- `find_live_room` is the quiet half of the live-room feature: nobody is told it
-- was asked. It answers on a conference URL or an invitation id, both of which
-- are knowable without being in the meeting — `conference_room_key` normalizes a
-- personal room to one stable string precisely so it matches across occurrences.
-- The migration before this made joining prove attendance or ask the host, and
-- left this one answering with a name and a start time to any active member of
-- the organization who could name the room.
--
-- So it is an enumeration oracle over one fact: who is recording, right now, in
-- a room you can name. Repeat it and it is a presence feed on a colleague.
--
-- The fix is not another gate — a gate here would take discovery away from
-- everyone whose calendar the server cannot see, which is most people, and the
-- offer to join is the whole point of the feature. It is to stop answering with
-- something worth collecting. An unproven caller learns only that somebody is
-- recording; the name arrives with `join_live_room`, which the host is told
-- about and can refuse. A caller whose own synced calendar carries the meeting
-- already had the right to the name and keeps it.

drop function public.find_live_room(text, text);

create function public.find_live_room(
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns table (host_name text, started_at timestamptz)
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room  text := public.conference_room_key(p_conference_url);
    v_ical  text := nullif(btrim(coalesce(p_ical_uid, '')), '');
    v_org   uuid;
    v_host  public.meeting_start_leases;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    select active_org_id into v_org from public.profiles where user_id = auth.uid();
    if v_org is null then
        return;
    end if;

    v_host := public._live_lease_in_org(v_org, v_ical, v_room, auth.uid());
    if v_host.meeting_id is null then
        return;
    end if;

    -- Null rather than a second column saying "withheld": the client renders a
    -- name when it has one and "Someone is recording this meeting" when it does
    -- not, and a shape that has always been nullable needs no new version.
    return query
    select case
               when public._calendar_proves_attendance(auth.uid(), v_host.ical_uid, v_host.room_key)
                   then public._display_name(v_host.user_id)
               else null
           end,
           v_host.granted_at;
end;
$$;

revoke all on function public.find_live_room(text, text) from public, anon;
grant execute on function public.find_live_room(text, text) to authenticated;
