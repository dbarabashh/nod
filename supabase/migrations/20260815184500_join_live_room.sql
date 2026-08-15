-- Joining and leaving a colleague's live room, and hearing that it moved.
--
-- The caller never names the meeting they are joining, and never learns its id.
-- They describe the meeting **they** are in — the invitation id and join link
-- their own calendar gave them — and the server finds the host. So the only way
-- to reach somebody's live transcript is to be able to prove, from your own
-- calendar, that you are in the same meeting; there is no room id to guess and
-- none to pass around.
--
-- Which also settles who may listen: not "anyone in the organization", but
-- somebody holding the same invitation. A colleague who is not in the meeting
-- has nothing to send that would match.

create function public.join_live_room(
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns table (listener_id uuid, host_name text, host_meeting_id uuid, started_at timestamptz)
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room  text := public.conference_room_key(p_conference_url);
    v_ical  text := nullif(btrim(coalesce(p_ical_uid, '')), '');
    v_org   uuid;
    v_host  public.meeting_start_leases;
    v_id    uuid;
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

    select l.* into v_host
      from public.meeting_start_leases l
      join public.org_members m
        on m.org_id = v_org and m.user_id = l.user_id and m.status = 'active'
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
    if v_host.meeting_id is null then
        return;
    end if;

    insert into public.room_listeners (host_meeting_id, listener_user_id, org_id)
    values (v_host.meeting_id, auth.uid(), v_org)
    on conflict do nothing
    returning id into v_id;

    if v_id is null then
        select rl.id into v_id from public.room_listeners rl
         where rl.host_meeting_id = v_host.meeting_id
           and rl.listener_user_id = auth.uid()
           and rl.left_at is null;
    end if;

    -- The host learns immediately, because being listened to without knowing is
    -- the one outcome this feature must never produce.
    perform public._notify_access_changed('user:' || v_host.user_id::text);

    return query
    select v_id,
           coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           v_host.meeting_id,
           v_host.granted_at
      from auth.users u
      left join public.profiles p on p.user_id = v_host.user_id
     where u.id = v_host.user_id;
end;
$$;

revoke all on function public.join_live_room(text, text) from public, anon;
grant execute on function public.join_live_room(text, text) to authenticated;

create function public.leave_live_room(p_listener uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_host uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    update public.room_listeners
       set left_at = now()
     where id = p_listener
       and listener_user_id = auth.uid()
       and left_at is null
    returning host_meeting_id into v_host;

    if v_host is not null then
        select l.user_id into v_host from public.meeting_start_leases l where l.meeting_id = v_host;
        perform public._notify_access_changed('user:' || v_host::text);
    end if;
end;
$$;

revoke all on function public.leave_live_room(uuid) from public, anon;
grant execute on function public.leave_live_room(uuid) to authenticated;

-- ── Telling a listener the transcript moved ─────────────────────────────────

-- Contentless, like every other channel here. The payload says only that there
-- is more; the listener re-reads under its own policy, so what a person may see
-- is decided in exactly one place — the transcript's RLS — rather than in two
-- that can disagree.
create policy "listen to a live room you joined"
    on realtime.messages
    for select
    to authenticated
    using (
        realtime.messages.extension = 'broadcast'
        and exists (
            select 1 from public.room_listeners rl
             where rl.listener_user_id = (select auth.uid())
               and rl.left_at is null
               and realtime.topic() = 'room:' || rl.host_meeting_id::text
               and (select public.is_live_room_listener(rl.host_meeting_id))
        )
    );

create function public._broadcast_room_transcript()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    -- Only when somebody is actually listening. A solo recording is the normal
    -- case and must not pay for a channel nobody is on.
    if exists (
        select 1 from public.room_listeners rl
         where rl.host_meeting_id = new.meeting_id and rl.left_at is null
    ) then
        perform public._notify_access_changed('room:' || new.meeting_id::text);
    end if;
    return null;
end;
$$;

revoke all on function public._broadcast_room_transcript() from public, anon, authenticated;

create trigger broadcast_room_transcript
    after insert on public.meeting_transcripts
    for each row execute function public._broadcast_room_transcript();
