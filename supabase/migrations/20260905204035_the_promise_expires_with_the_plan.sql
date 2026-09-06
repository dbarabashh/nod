-- Drop the grandfathered "unlimited hours" pin when the plan changes.
--
-- `20260905203754` gave a subscription its own `hours_are_unlimited`, so somebody
-- who bought Pro while it promised unlimited hours keeps that promise after the
-- plan starts publishing a ceiling. The pin means "keep what you bought on THIS
-- plan", and `20260802103325` already established that such a pin has to expire
-- the moment a different plan is bought — it did that for `hours_per_month` and
-- nothing else existed to clear at the time.
--
-- Without this a grandfathered Pro who moves to Starter carries an uncapped
-- allowance onto the cheaper plan indefinitely, which is the same defect that
-- migration was written to fix, one column later.
--
-- A cycle switch is not a plan change, so a Pro subscriber moving from monthly
-- to yearly keeps the promise. Everything else in the function is unchanged from
-- `20260802103325`; plpgsql has no way to patch one statement.

create or replace function public.apply_paddle_subscription(
    p_user_id         uuid,
    p_customer_id     text,
    p_subscription_id text,
    p_price_id        text,
    p_paddle_status   text,
    p_period_start    timestamptz,
    p_period_end      timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan   text;
    v_status text;
begin
    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;
    -- A price we can't map must NOT silently grant a plan (the old
    -- `coalesce(..., 'starter')` mis-provisioned paying users when the catalog
    -- wasn't seeded). Raising makes the webhook 5xx so Paddle retries and the
    -- misconfiguration is visible instead of charging for the wrong tier.
    if v_plan is null then
        raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
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
        updated_at
    ) values (
        p_user_id, v_plan, v_status,
        p_period_start, p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        now()
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
        hours_are_unlimited    = case
                                    when s.plan is distinct from v_plan
                                    then null
                                    else s.hours_are_unlimited
                                 end,
        updated_at             = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;
