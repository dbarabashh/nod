-- Three things a seat has to mean once an organization can buy one.
--
-- 1. Paddle can write it. `apply_paddle_org_subscription` is the organization's
--    counterpart to `apply_paddle_subscription`, with the same event ordering
--    and the same advisory lock, keyed on the organization instead of the user.
--    Seats come from the subscription item's quantity, which is the only place
--    Paddle records how many were bought.
--
-- 2. Joining costs one. An organization holding a plan cannot take on more
--    active members than it pays for. Refusing the join is the honest failure:
--    letting somebody in uncovered means an administrator invited a colleague
--    and silently got them nothing, which they would discover from the
--    colleague rather than from us. An organization with no plan is unaffected —
--    everybody there pays for themselves, as they always did.
--
-- 3. Listening costs one. `join_live_room` checked authentication and active
--    membership and nothing else, so a colleague on an expired plan could sit in
--    a paying member's room and receive the live transcript, the live findings
--    and the finished summary — the three things `20260816260000` deliberately
--    gives a listener. That was defensible while the only thing being sold was a
--    personal plan and sharing was a courtesy. It is not defensible once the
--    shared room is the product being charged for, so a listener now needs an
--    entitlement of their own: the organization's seat, or their own plan.
--
-- The gate is deliberately "active or trialing" rather than a feature flag.
-- Listening is not a tier's feature, it is the workspace working; what is being
-- refused is a lapsed account riding on a live one.

create or replace function public.apply_paddle_org_subscription(
    p_org_id            uuid,
    p_customer_id       text,
    p_subscription_id   text,
    p_price_id          text,
    p_paddle_status     text,
    p_seats             integer,
    p_period_start      timestamptz,
    p_period_end        timestamptz,
    p_event_id          text,
    p_event_occurred_at timestamptz,
    p_purchased_by      uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan text;
    v_existing_plan text;
    v_existing_event_at timestamptz;
    v_existing_event_id text;
    v_status text;
    v_seats integer;
begin
    if p_org_id is null then
        raise exception 'apply_paddle_org_subscription: organization required';
    end if;
    if nullif(trim(p_event_id), '') is null or p_event_occurred_at is null then
        raise exception 'apply_paddle_org_subscription: event identity required';
    end if;

    perform pg_advisory_xact_lock(hashtext('paddle_org_subscription:' || p_org_id::text));

    select plan, last_paddle_event_at, last_paddle_event_id
      into v_existing_plan, v_existing_event_at, v_existing_event_id
      from public.org_subscriptions
     where org_id = p_org_id
     for update;
    if found
       and v_existing_event_at is not null
       and p_event_occurred_at <= v_existing_event_at then
        return false;
    end if;

    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    if v_plan is null then
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_org_subscription: unmapped paddle price_id %', p_price_id;
        else
            return false;
        end if;
    end if;

    v_status := case p_paddle_status
        when 'active'   then 'active'
        when 'trialing' then 'trialing'
        when 'past_due' then 'past_due'
        when 'paused'   then 'past_due'
        when 'canceled' then 'canceled'
        else 'past_due'
    end;

    -- A cancellation event carries no meaningful quantity, so it must not shrink
    -- the organization to one seat on its way out.
    v_seats := greatest(coalesce(p_seats, 0), 1);

    insert into public.org_subscriptions as o (
        org_id, plan, status, seats,
        current_period_start, current_period_end,
        paddle_customer_id, paddle_subscription_id, paddle_price_id,
        purchased_by, converted_at, updated_at,
        last_paddle_event_at, last_paddle_event_id
    ) values (
        p_org_id, v_plan, v_status, v_seats,
        coalesce(p_period_start, p_event_occurred_at), p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        p_purchased_by,
        case when v_status in ('active', 'past_due') then p_event_occurred_at end,
        now(), p_event_occurred_at, p_event_id
    )
    on conflict (org_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        seats                  = case when p_seats is null then o.seats else v_seats end,
        current_period_start   = coalesce(p_period_start, o.current_period_start),
        current_period_end     = coalesce(p_period_end, o.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, o.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, o.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, o.paddle_price_id),
        purchased_by           = coalesce(o.purchased_by, p_purchased_by),
        limit_overrides        = case
                                    when o.plan is distinct from v_plan
                                    then coalesce(o.limit_overrides, '{}'::jsonb) - 'hours_per_month'
                                    else o.limit_overrides
                                 end,
        hours_are_unlimited    = case
                                    when o.plan is distinct from v_plan
                                    then null
                                    else o.hours_are_unlimited
                                 end,
        converted_at           = case
                                    when v_status in ('active', 'past_due')
                                    then coalesce(o.converted_at, p_event_occurred_at)
                                    else o.converted_at
                                 end,
        updated_at             = now(),
        last_paddle_event_at   = p_event_occurred_at,
        last_paddle_event_id   = p_event_id;
    return true;
end;
$$;

revoke all on function public.apply_paddle_org_subscription(uuid, text, text, text, text, integer, timestamptz, timestamptz, text, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.apply_paddle_org_subscription(uuid, text, text, text, text, integer, timestamptz, timestamptz, text, timestamptz, uuid) to service_role;

create or replace function public.accept_org_invite(p_token uuid)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_invite public.org_invites%rowtype;
    v_email text;
    v_org_sub public.org_subscriptions%rowtype;
    v_taken integer;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select lower(btrim(email)) into v_email from auth.users where id = auth.uid();

    select * into v_invite from public.org_invites where token = p_token;
    if v_invite.id is null then
        raise exception 'this invite is not valid' using errcode = '42704';
    end if;
    if v_invite.accepted_at is not null or v_invite.revoked_at is not null then
        raise exception 'this invite has already been used' using errcode = '42704';
    end if;
    if v_invite.expires_at <= now() then
        raise exception 'this invite has expired' using errcode = '42704';
    end if;
    if lower(v_invite.email) <> coalesce(v_email, '') then
        raise exception 'this invite was sent to a different address' using errcode = '42501';
    end if;

    -- Somebody rejoining already had a seat, so they are not counted against the
    -- organization twice.
    select * into v_org_sub from public.org_subscriptions where org_id = v_invite.org_id;
    if found and v_org_sub.status in ('trialing', 'active', 'past_due') then
        select count(*) into v_taken
          from public.org_members m
         where m.org_id = v_invite.org_id
           and m.status = 'active'
           and m.user_id <> auth.uid();
        if v_taken >= v_org_sub.seats then
            raise exception 'this workspace has no seats left' using errcode = '23514';
        end if;
    end if;

    -- Rejoining reactivates the original row rather than adding a second one, so
    -- the audit trail of a person's time in an organization stays one story.
    insert into public.org_members (org_id, user_id, role)
    values (v_invite.org_id, auth.uid(), v_invite.role)
    on conflict (org_id, user_id) do update
        set role = excluded.role, status = 'active', joined_at = now();

    if v_invite.team_id is not null then
        insert into public.team_members (team_id, user_id, added_by)
        values (v_invite.team_id, auth.uid(), v_invite.invited_by)
        on conflict (team_id, user_id) do nothing;
    end if;

    update public.org_invites
       set accepted_at = now(), accepted_by = auth.uid()
     where id = v_invite.id;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_invite.org_id, auth.uid(), 'member.joined', 'user', auth.uid());

    return v_invite.org_id;
end;
$$;

revoke all on function public.accept_org_invite(uuid) from public, anon;
grant execute on function public.accept_org_invite(uuid) to authenticated;

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

    -- A room is somebody's paid capture. Listening in gives the transcript, the
    -- live findings and the finished summary, so it needs a live entitlement of
    -- the listener's own — the workspace seat, or their personal plan.
    if (public.resolve_entitlement(auth.uid())->>'status') not in ('trialing', 'active') then
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

revoke all on function public.join_live_room(text, text) from public, anon;
grant execute on function public.join_live_room(text, text) to authenticated;
