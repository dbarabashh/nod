-- apply_paddle_subscription 500s on any cancellation whose event carries no
-- current_billing_period (Paddle sends current_billing_period: null once a
-- subscription is canceled — there's no "current" period left).
--
-- Postgres validates NOT NULL on current_period_start while building the
-- candidate row for INSERT, before ON CONFLICT ever gets a chance to divert
-- to DO UPDATE. So even an existing subscriber (whose real period the DO
-- UPDATE branch would have preserved via coalesce(p_period_start,
-- s.current_period_start)) hits the NOT NULL violation first, and Paddle's
-- webhook gets a 500 on every retry — this is what stranded Joseph
-- Dapuzzo's subscription on a stale "active" status past his real
-- cancellation.
--
-- Fix: seed the INSERT branch's current_period_start with now() when
-- p_period_start is null. This only changes behaviour for a genuinely new
-- row (first event ever seen for a user with no existing subscription) —
-- the placeholder is immediately correct-enough (today) and gets overwritten
-- by the next event anyway. The ON CONFLICT DO UPDATE branch is untouched:
-- existing subscribers keep coalescing to their real stored period, exactly
-- as before.

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
    v_plan          text;
    v_existing_plan text;
    v_status        text;
begin
    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;

    if v_plan is null then
        select plan into v_existing_plan from public.subscriptions where user_id = p_user_id;
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
        else
            return;
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
        converted_at, updated_at
    ) values (
        p_user_id, v_plan, v_status,
        coalesce(p_period_start, now()), p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        case when v_status in ('active', 'past_due') then now() end,
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
        converted_at           = case
                                    when v_status in ('active', 'past_due')
                                    then coalesce(s.converted_at, now())
                                    else s.converted_at
                                 end,
        updated_at             = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;
