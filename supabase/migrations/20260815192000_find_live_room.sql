-- Seeing that a room is there, without stepping into it.
--
-- `join_live_room` both finds and joins, which is wrong for the moment the offer
-- appears: joining notifies the host, and the host being told somebody is
-- listening before that person has decided to listen is a lie about what
-- happened.
--
-- Same rule as joining, minus the write: you must be able to name the meeting
-- from your own calendar, and the host must be a live recorder in your
-- organization. Answers a name, never an id.

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
    v_room text := public.conference_room_key(p_conference_url);
    v_ical text := nullif(btrim(coalesce(p_ical_uid, '')), '');
    v_org  uuid;
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

    return query
    select coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           l.granted_at
      from public.meeting_start_leases l
      join public.org_members m
        on m.org_id = v_org and m.user_id = l.user_id and m.status = 'active'
      join auth.users u on u.id = l.user_id
      left join public.profiles p on p.user_id = l.user_id
     where l.org_id = v_org
       and l.user_id <> auth.uid()
       and l.status = 'active'
       and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds'
       and (
            (v_ical is not null and l.ical_uid = v_ical)
            or (v_room is not null and l.room_key = v_room)
       )
     order by l.granted_at
     limit 1;
end;
$$;

revoke all on function public.find_live_room(text, text) from public, anon;
grant execute on function public.find_live_room(text, text) to authenticated;

-- Who is listening, for the host to see. Names only, and only to the person
-- being listened to.
create function public.room_listeners_of(p_meeting uuid)
    returns table (listener_name text)
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.meeting_start_leases l
         where l.meeting_id = p_meeting and l.user_id = auth.uid()
    ) then
        return;
    end if;

    return query
    select coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1))
      from public.room_listeners rl
      join auth.users u on u.id = rl.listener_user_id
      left join public.profiles p on p.user_id = rl.listener_user_id
     where rl.host_meeting_id = p_meeting and rl.left_at is null
     order by rl.joined_at;
end;
$$;

revoke all on function public.room_listeners_of(uuid) from public, anon;
grant execute on function public.room_listeners_of(uuid) to authenticated;
