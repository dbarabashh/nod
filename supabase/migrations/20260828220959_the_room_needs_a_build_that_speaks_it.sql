-- The live room answers only builds that understand what it now answers with.
--
-- `join_live_room` gained a `status`, and a join the server cannot prove from
-- the caller's own calendar lands as `pending` until the host approves it. A
-- build that predates that reads the row as an ordinary join: the listener
-- watches a bar whose transcript never arrives, and the host — whose
-- `room_listeners_of` now returns only approved rows — never sees a request to
-- answer. Neither side is told anything. Two such builds in one room is a dead
-- end with no error in it.
--
-- No shipped client is affected today: `main` carries no live-room code at all
-- and the released build is 69, so nothing in the wild calls these functions.
-- The gate exists so that stays true however the feature is rolled out — a
-- staged release, a user who has not restarted, a rollback — rather than
-- resting on the order two deploys happen to land in.
--
-- Modelled on `meeting_lease_required_build`: same table, same sentinel, same
-- monotonic service-role activation. `2147483647` means no build qualifies, so
-- the feature is off in every environment until somebody turns it on with the
-- build number that speaks the protocol. Per `.agents/rules/supabase.md` the
-- real value is environment-specific and set per branch, never in a migration.
--
-- Both ends are checked. Gating only the caller would still let a new listener
-- file a request against a host who cannot see it.

alter table public.app_config
    add column if not exists live_room_required_build integer not null default 2147483647;

-- `profiles.app_build` is stamped by `llm-proxy` on the first call after a
-- version changes, so it is current within one request of an upgrade. Null — a
-- fresh install that has not transcribed anything yet — does not qualify, which
-- is the safe answer rather than the convenient one.
--
-- The `macos` row: the live room is a desktop surface (the notch bar hosts it
-- and `ScreenCaptureKit` records it), and `app_config` is keyed by platform
-- rather than carrying one gate for everything.
create function public._build_speaks_live_room(p_user uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
          from public.app_config c
          join public.profiles p on p.user_id = p_user
         where c.platform = 'macos'
           and p.app_build is not null
           and p.app_build >= c.live_room_required_build
    );
$$;

revoke all on function public._build_speaks_live_room(uuid) from public, anon, authenticated;

-- ── The two doors ───────────────────────────────────────────────────────────
--
-- Only discovery and joining. `leave_live_room`, `approve_room_listener` and
-- `deny_room_listener` are deliberately left open: somebody already in a room
-- has to be able to get out of it, and a host has to be able to answer a
-- request that is already sitting there, whatever build either is on.

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
    if not public._build_speaks_live_room(auth.uid()) then
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
    -- Not offered at all when the host could not answer a request, rather than
    -- offered and then refused at the join.
    if not public._build_speaks_live_room(v_host.user_id) then
        return;
    end if;

    return query
    select case
               when public._calendar_proves_attendance(auth.uid(), v_host.ical_uid, v_host.room_key)
                   then public._display_name(v_host.user_id)
               else null
           end,
           v_host.granted_at;
end;
$$;

create or replace function public.join_live_room(
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns table (
        listener_id uuid,
        host_name text,
        host_meeting_id uuid,
        started_at timestamptz,
        status text
    )
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room   text := public.conference_room_key(p_conference_url);
    v_ical   text := nullif(btrim(coalesce(p_ical_uid, '')), '');
    v_org    uuid;
    v_host   public.meeting_start_leases;
    v_id     uuid;
    v_status text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;
    if not public._build_speaks_live_room(auth.uid()) then
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
    if not public._build_speaks_live_room(v_host.user_id) then
        return;
    end if;

    v_status := case
        when public._calendar_proves_attendance(auth.uid(), v_host.ical_uid, v_host.room_key)
            then 'joined'
        else 'pending'
    end;

    insert into public.room_listeners (host_meeting_id, listener_user_id, org_id, status)
    values (v_host.meeting_id, auth.uid(), v_org, v_status)
    on conflict do nothing
    returning id into v_id;

    if v_id is null then
        select rl.id, rl.status into v_id, v_status
          from public.room_listeners rl
         where rl.host_meeting_id = v_host.meeting_id
           and rl.listener_user_id = auth.uid()
           and rl.left_at is null;
    end if;

    perform public._notify_access_changed('user:' || v_host.user_id::text);

    return query
    select v_id, public._display_name(v_host.user_id), v_host.meeting_id, v_host.granted_at, v_status;
end;
$$;

-- ── Turning it on ───────────────────────────────────────────────────────────

-- Monotonic, like `activate_meeting_lease_enforcement`: a retry or a typo can
-- lower the gate only by going backwards through this function, which refuses.
create function public.activate_live_room(p_compatible_build integer)
    returns jsonb
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_current integer;
begin
    if p_compatible_build <= 0 then
        return jsonb_build_object('activated', false, 'error', 'invalid_build');
    end if;

    select live_room_required_build into v_current
      from public.app_config
     where platform = 'macos'
     for update;
    if not found then
        return jsonb_build_object('activated', false, 'error', 'config_missing');
    end if;
    if v_current <> 2147483647 and p_compatible_build < v_current then
        return jsonb_build_object('activated', false, 'error', 'build_downgrade');
    end if;

    update public.app_config
       set live_room_required_build = p_compatible_build,
           updated_at = now()
     where platform = 'macos';

    return jsonb_build_object('activated', true, 'build', p_compatible_build);
end;
$$;

revoke all on function public.activate_live_room(integer) from public, anon, authenticated;
grant execute on function public.activate_live_room(integer) to service_role;
