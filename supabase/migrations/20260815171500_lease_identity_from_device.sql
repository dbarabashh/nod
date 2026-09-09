-- Letting the on-device calendar identify a meeting too.
--
-- `_stamp_lease_identity` reads `calendar_events`, which only exists for someone
-- who connected Google Calendar through Nango. The macOS Calendars permission —
-- the path most people already have, and the only one that reaches an iCloud or
-- Exchange account — fed none of it, so every recording made that way was
-- anonymous to the matcher.
--
-- The client sends what EventKit gives it: the calendar server's own identifier
-- for the event, and the join link as written. It does **not** send a room key.
-- Deriving that stays here, in `conference_room_key`, so the two calendar
-- sources cannot normalize a Zoom link differently and quietly stop matching
-- each other.
--
-- Fills only what is empty, so a connected Google Calendar — which the server
-- read itself — always wins over what a client claims. And only for a lease the
-- caller owns, still active, granted moments ago: after that the recording is
-- under way and its identity is settled.

create function public.set_lease_identity(
    p_meeting uuid,
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room text := public.conference_room_key(p_conference_url);
    v_ical text := nullif(btrim(coalesce(p_ical_uid, '')), '');
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    update public.meeting_start_leases
       set ical_uid = coalesce(ical_uid, v_ical),
           room_key = coalesce(room_key, v_room)
     where meeting_id = p_meeting
       and user_id = auth.uid()
       and status = 'active'
       and granted_at > now() - interval '2 minutes'
       and (ical_uid is null or room_key is null);
end;
$$;

revoke all on function public.set_lease_identity(uuid, text, text) from public, anon;
grant execute on function public.set_lease_identity(uuid, text, text) to authenticated;
