-- Put the pin-clearing on the function the webhook actually calls, and give the
-- legacy shim its delegation back.
--
-- `20260905204035` added `hours_are_unlimited = null on plan change` to
-- `apply_paddle_subscription(uuid, text, text, text, text, timestamptz,
-- timestamptz)`. That seven-argument name is not the live path: `20260811151000`
-- introduced a nine-argument version carrying the Paddle event identity, made it
-- the one `paddle-webhook` calls, and reduced the old signature to a shim that
-- delegates to it for callers that predate event ordering. Postgres overloads by
-- signature, so writing the old name replaced the shim's body rather than the
-- live function — the pin never expired where it mattered, and the shim stopped
-- delegating, losing event ordering and `converted_at` for anything still on it.
--
-- Both halves are restored here: the nine-argument function gains the clearing,
-- and the shim goes back to being a shim. The wrong migration is left as it was
-- applied; a repair belongs in a forward migration, not in rewritten history.

create or replace function public.apply_paddle_subscription(
    p_user_id uuid,
    p_customer_id text,
    p_subscription_id text,
    p_price_id text,
    p_paddle_status text,
    p_period_start timestamptz,
    p_period_end timestamptz,
    p_event_id text,
    p_event_occurred_at timestamptz
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
begin
    if nullif(trim(p_event_id), '') is null or p_event_occurred_at is null then
        raise exception 'apply_paddle_subscription: event identity required';
    end if;

    perform pg_advisory_xact_lock(hashtext('paddle_subscription:' || p_user_id::text));

    select plan, last_paddle_event_at, last_paddle_event_id
      into v_existing_plan, v_existing_event_at, v_existing_event_id
      from public.subscriptions
     where user_id = p_user_id
     for update;
    -- Backfilled and shim-written rows carry no real event time, so they never
    -- suppress the first genuine event.
    if found
       and v_existing_event_at is not null
       and v_existing_event_id is distinct from 'migration-watermark'
       and v_existing_event_id not like 'legacy:%'
       and p_event_occurred_at <= v_existing_event_at then
        return false;
    end if;

    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    if v_plan is null then
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
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

    insert into public.subscriptions as s (
        user_id, plan, status,
        current_period_start, current_period_end,
        paddle_customer_id, paddle_subscription_id, paddle_price_id,
        converted_at, updated_at, last_paddle_event_at, last_paddle_event_id
    ) values (
        p_user_id, v_plan, v_status,
        coalesce(p_period_start, p_event_occurred_at), p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        case when v_status in ('active', 'past_due') then p_event_occurred_at end,
        now(), p_event_occurred_at, p_event_id
    )
    on conflict (user_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        current_period_start   = coalesce(p_period_start, s.current_period_start),
        current_period_end     = coalesce(p_period_end, s.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, s.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, s.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, s.paddle_price_id),
        limit_overrides        = case
                                    when s.plan is distinct from v_plan
                                    then coalesce(s.limit_overrides, '{}'::jsonb) - 'hours_per_month'
                                    else s.limit_overrides
                                 end,
        -- The grandfathered "no ceiling" promise is bought on a plan, so it
        -- expires with it. A cycle switch is not a plan change and keeps it.
        hours_are_unlimited    = case
                                    when s.plan is distinct from v_plan
                                    then null
                                    else s.hours_are_unlimited
                                 end,
        converted_at           = case
                                    when v_status in ('active', 'past_due')
                                    then coalesce(s.converted_at, p_event_occurred_at)
                                    else s.converted_at
                                 end,
        updated_at             = now(),
        last_paddle_event_at   = p_event_occurred_at,
        last_paddle_event_id   = p_event_id;
    return true;
end;
$$;

create or replace function public.apply_paddle_subscription(
    p_user_id uuid,
    p_customer_id text,
    p_subscription_id text,
    p_price_id text,
    p_paddle_status text,
    p_period_start timestamptz,
    p_period_end timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_last_event_at timestamptz;
    v_last_event_id text;
begin
    select last_paddle_event_at, last_paddle_event_id
      into v_last_event_at, v_last_event_id
      from public.subscriptions
     where user_id = p_user_id;
    if found
       and v_last_event_id is distinct from 'migration-watermark'
       and v_last_event_id not like 'legacy:%' then
        return;
    end if;
    perform public.apply_paddle_subscription(
        p_user_id, p_customer_id, p_subscription_id, p_price_id, p_paddle_status,
        p_period_start, p_period_end,
        'legacy:' || gen_random_uuid()::text,
        coalesce(v_last_event_at, now() - interval '1 second') + interval '1 microsecond'
    );
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz, text, timestamptz) to service_role;
