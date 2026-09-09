-- The live-room rules, said once each.
--
-- `20260815182000` argued that a second staleness rule "would eventually
-- disagree with the first" — and then the three migrations around it shipped the
-- 90-second window four times and the display-name expression six. This puts
-- both behind one function apiece and rewrites every caller to ask.
--
-- It also fixes three costs the copies hid:
--
--   * the transcript broadcast was per row, so one 30-line upsert probed
--     `room_listeners` thirty times and sent thirty realtime messages for a
--     single statement;
--   * `meeting_start_leases_identity_idx` could not serve the query it was added
--     for — `coalesce(last_used_at, granted_at) > …` is not sargable against the
--     bare column, and the `ical_uid`/`room_key` match it never covered at all,
--     so every lookup degraded to a scan of every lease the org had ever made;
--   * two RLS policies called a `SECURITY DEFINER` function per row. The
--     `(select fn(x))` wrapper only hoists when the argument is constant, and a
--     column reference is not — so a listener reading a 2,000-line transcript
--     ran 2,000 multi-table joins. Asking for the *set* of readable meetings
--     instead lets the planner build it once.

-- ── The two rules ───────────────────────────────────────────────────────────

create function public._display_name(p_user uuid)
    returns text
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1))
      from auth.users u
      left join public.profiles p on p.user_id = u.id
     where u.id = p_user;
$$;

revoke all on function public._display_name(uuid) from public, anon;

-- "Somebody else in this organization is recording the meeting I named, right
-- now." The 90 seconds is the same window `start_meeting_lease` uses to call a
-- lease abandoned, and this is now the only place it is written.
create function public._live_lease_in_org(
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
     order by l.granted_at
     limit 1;
$$;

revoke all on function public._live_lease_in_org(uuid, text, text, uuid) from public, anon;

-- ── An index the lookup can actually use ────────────────────────────────────

drop index public.meeting_start_leases_identity_idx;

-- One per identity key, so the OR resolves as a bitmap-or on the selective
-- column and the staleness window is a cheap recheck rather than the filter
-- everything else runs through.
create index meeting_start_leases_ical_idx
    on public.meeting_start_leases (org_id, ical_uid)
    where ical_uid is not null and status = 'active';

create index meeting_start_leases_room_idx
    on public.meeting_start_leases (org_id, room_key)
    where room_key is not null and status = 'active';

-- ── The three callers ───────────────────────────────────────────────────────

create or replace function public.concurrent_recording(p_meeting uuid)
    returns table (owner_name text, started_at timestamptz)
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org   uuid;
    v_ical  text;
    v_room  text;
    v_other public.meeting_start_leases;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select l.org_id, l.ical_uid, l.room_key
      into v_org, v_ical, v_room
      from public.meeting_start_leases l
     where l.meeting_id = p_meeting and l.user_id = auth.uid();
    if v_org is null or (v_ical is null and v_room is null) then
        return;
    end if;

    v_other := public._live_lease_in_org(v_org, v_ical, v_room, auth.uid());
    if v_other.meeting_id is null then
        return;
    end if;

    return query select public._display_name(v_other.user_id), v_other.granted_at;
end;
$$;

create or replace function public.find_live_room(
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

    return query select public._display_name(v_host.user_id), v_host.granted_at;
end;
$$;

create or replace function public.join_live_room(
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

    v_host := public._live_lease_in_org(v_org, v_ical, v_room, auth.uid());
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
    select v_id, public._display_name(v_host.user_id), v_host.meeting_id, v_host.granted_at;
end;
$$;

create or replace function public.room_listeners_of(p_meeting uuid)
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
    select public._display_name(rl.listener_user_id)
      from public.room_listeners rl
     where rl.host_meeting_id = p_meeting and rl.left_at is null
     order by rl.joined_at;
end;
$$;

-- ── One broadcast per statement, not per line ───────────────────────────────

create or replace function public._broadcast_room_transcript()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform public._notify_access_changed('room:' || t.meeting_id::text)
      from (select distinct i.meeting_id from ins i) t
     where exists (
         select 1 from public.room_listeners rl
          where rl.host_meeting_id = t.meeting_id and rl.left_at is null
     );
    return null;
end;
$$;

drop trigger broadcast_room_transcript on public.meeting_transcripts;

create trigger broadcast_room_transcript
    after insert on public.meeting_transcripts
    referencing new table as ins
    for each statement execute function public._broadcast_room_transcript();

-- ── Policies that ask once ──────────────────────────────────────────────────

-- Set-returning and argument-free on purpose: with nothing correlated to the
-- row, the planner runs it once per query and hashes the result.
create function public._live_rooms_i_listen_to()
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select rl.host_meeting_id
      from public.room_listeners rl
      join public.meeting_start_leases l on l.meeting_id = rl.host_meeting_id
      join public.org_members m
        on m.org_id = rl.org_id and m.user_id = rl.listener_user_id and m.status = 'active'
     where rl.listener_user_id = (select auth.uid())
       and rl.left_at is null
       and l.status = 'active'
       and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds';
$$;

create function public._meetings_granted_to_me()
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select ms.meeting_id
      from public.meeting_grants ms
     where (ms.team_id is not null and exists (
               select 1
                 from public.team_members tm
                 join public.teams t on t.id = tm.team_id and t.deleted_at is null
                 join public.org_members om
                   on om.org_id = t.org_id and om.user_id = tm.user_id and om.status = 'active'
                where tm.team_id = ms.team_id and tm.user_id = (select auth.uid())
           ))
        or (ms.org_id is not null and exists (
               select 1 from public.org_members om
                where om.org_id = ms.org_id and om.user_id = (select auth.uid()) and om.status = 'active'
           ));
$$;

revoke all on function public._live_rooms_i_listen_to() from public, anon;
revoke all on function public._meetings_granted_to_me() from public, anon;
grant execute on function public._live_rooms_i_listen_to() to authenticated;
grant execute on function public._meetings_granted_to_me() to authenticated;

alter policy "listeners read a live room's transcript" on public.meeting_transcripts
    using (meeting_transcripts.meeting_id in (select public._live_rooms_i_listen_to()));

alter policy "members read meetings shared directly" on public.meetings
    using (deleted_at is null and meetings.id in (select public._meetings_granted_to_me()));

alter policy "members read transcripts shared directly" on public.meeting_transcripts
    using (meeting_transcripts.meeting_id in (select public._meetings_granted_to_me()));

alter policy "members read action items shared directly" on public.action_items
    using (action_items.meeting_id is not null
           and action_items.meeting_id in (select public._meetings_granted_to_me()));

alter policy "members read embeddings shared directly" on public.session_embeddings
    using (session_embeddings.meeting_id in (select public._meetings_granted_to_me()));

alter policy "audience reads its meeting shares" on public.meeting_grants
    using (meeting_grants.meeting_id in (select public._meetings_granted_to_me()));

-- ── One trigger function for both share tables ──────────────────────────────

-- `folder_shares` and `meeting_grants` both expose `(team_id, org_id)`, and the
-- topic naming was spelled twice. Read as json so one body serves both rowtypes.
create or replace function public._broadcast_share_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v jsonb := to_jsonb(coalesce(new, old));
begin
    if v ->> 'team_id' is not null then
        perform public._notify_access_changed('team:' || (v ->> 'team_id'));
    else
        perform public._notify_access_changed('org:' || (v ->> 'org_id'));
    end if;
    return null;
end;
$$;

drop trigger broadcast_access on public.meeting_grants;

create trigger broadcast_access after insert or delete on public.meeting_grants
    for each row execute function public._broadcast_share_change();

drop function public._broadcast_meeting_grant_change();
