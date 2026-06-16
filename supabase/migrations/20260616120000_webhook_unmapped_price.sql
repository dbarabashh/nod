-- apply_paddle_subscription: don't let an unmapped price_id wedge the webhook.
--
-- 20260611120000 made the function RAISE on any price_id not in plan_prices, to
-- surface a misconfigured catalog as a retried webhook instead of mis-provisioning
-- a payer. But it fires on EVERY event — so a `subscription.canceled`/`past_due`
-- carrying a discontinued/unmapped price (or an `active` event while the branch
-- still holds the seeded pri_REPLACE_* placeholders) 500s forever and the change
-- is never applied: a cancellation that never de-provisions, or a payer never
-- provisioned.
--
-- Keep the fail-loud guard where it matters (a NEW subscription whose price we
-- can't map is a real catalog bug), but for an existing subscriber fall back to
-- their current plan so status/period updates still land. A terminal event for a
-- user we've never seen has nothing to apply, so ack it quietly.

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
            -- Existing subscriber: keep their plan, just apply the status/period
            -- change this event carries (cancel, past_due, period roll, etc.).
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            -- A brand-new paying/trialing subscription whose price we can't map is
            -- a real catalog misconfiguration — fail loud so Paddle retries and it
            -- surfaces instead of granting the wrong tier.
            raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
        else
            -- Terminal/maintenance event for a user we've never provisioned —
            -- nothing to apply. Ack quietly so Paddle doesn't retry forever.
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
        updated_at             = now();
end;
$$;

revoke all on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_paddle_subscription(uuid, text, text, text, text, timestamptz, timestamptz) to service_role;
