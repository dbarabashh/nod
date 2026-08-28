-- `_live_lease_in_org` checks the caller too, not only the host.
--
-- It joined `org_members` on `l.user_id` — the host — and never on whoever was
-- asking. The organization came from `profiles.active_org_id`, which until the
-- migration before this one was a column any account could write to any value.
-- Together those meant a signed-in stranger could name an organization, be
-- believed, and be told who was recording in it.
--
-- `concurrent_recording` was never reachable that way: its organization comes
-- from the caller's own lease, which the server stamps. `find_live_room` and
-- `join_live_room` take it from the profile, and both omitted the check that
-- every sibling reader of that column makes. Putting it in the shared matcher
-- rather than in each of the three means a fourth caller cannot forget it.

create or replace function public._live_lease_in_org(
    p_org uuid,
    p_ical text,
    p_room text,
    p_excluding uuid
)
    returns public.meeting_start_leases
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select l.*
      from public.meeting_start_leases l
      join public.org_members m
        on m.org_id = p_org and m.user_id = l.user_id and m.status = 'active'
     where l.org_id = p_org
       and l.user_id <> p_excluding
       and l.status = 'active'
       and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds'
       and (
            (p_ical is not null and l.ical_uid = p_ical)
            or (p_room is not null and l.room_key = p_room)
       )
       and exists (
            select 1
              from public.org_members me
             where me.org_id = p_org
               and me.user_id = (select auth.uid())
               and me.status = 'active'
       )
     order by l.granted_at
     limit 1;
$$;

revoke all on function public._live_lease_in_org(uuid, text, text, uuid) from public, anon;
