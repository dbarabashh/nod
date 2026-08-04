-- Restore two behaviours 20260802103325 dropped from apply_paddle_subscription.
--
-- That migration restated the function "unchanged from 20260611120000", but
-- 20260611 was not the latest definition — 20260616120000 and 20260723110215
-- had each rewritten the body since. Restating from the older source silently
-- reverted both:
--
--   * `converted_at` (20260723110215) stopped being stamped, so the first
--     conversion after 2026-08-02 landed with a null and dropped out of
--     new_paying_30d on the founder dashboard;
--   * the unmapped-price fallback (20260616120000) came back as an
--     unconditional raise, so a canceled/past_due event carrying a price that
--     isn't in plan_prices 500s the webhook forever — the cancellation never
--     de-provisions and Paddle retries indefinitely.
--
-- This body is the union of all three: 20260616's price resolution, 20260723's
-- converted_at, 20260802's hours-pin clearing on a plan change.

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
        p_period_start, p_period_end,
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

update public.subscriptions
   set converted_at = current_period_start
 where status in ('active', 'past_due')
   and converted_at is null;
