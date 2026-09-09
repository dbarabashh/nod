-- An integration action is a metered thing, and a plan includes a number of them.
--
-- Every question that reaches a connected tool is a paid broker call, and until
-- now nothing in the product knew that: `plans.features` said which tools a plan
-- may connect, and nothing said how much it may ask of them. Measured over the
-- first week of September, one person asking Nod about Linear and Gmail
-- consumed more of the broker's credits than every calendar read combined, and
-- there was no ceiling anywhere on either side of the bill.
--
-- The unit is the integration credit: one per metered action. What is metered
-- is decided in `integration-action` — a read is, a write is not. Filing a
-- ticket after a meeting is what the tiers already promise and costs a single
-- call; asking Nod to read your inbox is the agentic use that scales without
-- bound, and that is what the pool is for. Calendar reads and the ticket-status
-- mirror stay outside the pool: nobody asked for them, so nobody should watch a
-- counter fall because of them. They are throttled instead.
--
-- One meter, not a new table. A metered action is one `usage_events` row of
-- kind `integration`, which gives it the `org_id` stamp, the period window and
-- the cost column every other billable thing already has. The pool is then
-- `seats × limit` for a workspace and `limit` for a person, spent by counting
-- those rows in the resolved period, and the resolver reports it beside the
-- hours so a client learns one shape.
--
-- A pack of credits rides the top-up machinery as it stands: `plan_prices` grows
-- `top_up_credits` beside `top_up_hours`, `usage_topups` grows `credits` beside
-- `hours`, and a purchase grants whichever the row carries. The Automation Pack
-- is seeded as placeholders per plan, dark until the Paddle price exists.

alter table public.usage_events drop constraint usage_events_kind_check;
alter table public.usage_events add constraint usage_events_kind_check
    check (kind in ('chat', 'transcribe', 'embed', 'speak', 'integration'));

create index if not exists usage_events_integration_user_idx
    on public.usage_events (user_id, created_at desc)
    where kind = 'integration';

update public.plans
   set limits = limits || jsonb_build_object('integration_credits_per_month', v.credits)
  from (values ('trial', 100), ('starter', 100), ('pro', 500), ('teams', 500)) as v (plan, credits)
 where plans.plan = v.plan
   and not (plans.limits ? 'integration_credits_per_month');

alter table public.plan_prices
    add column if not exists top_up_credits numeric check (top_up_credits is null or top_up_credits > 0);

alter table public.usage_topups
    add column if not exists credits numeric check (credits is null or credits > 0);

alter table public.usage_topups
    drop constraint if exists usage_topups_hours_check;
alter table public.usage_topups
    alter column hours drop not null;
alter table public.usage_topups
    add constraint usage_topups_grants_something
    check ((hours is not null and hours > 0) or (credits is not null and credits > 0));

alter table public.topup_checkout_intents
    drop constraint if exists topup_checkout_intents_sku_check;
alter table public.topup_checkout_intents
    add constraint topup_checkout_intents_sku_check
    check (sku in ('starter_5h_usd_12', 'pro_10h_usd_29', 'automation_1000_usd_10'));

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, top_up_credits, available_for_new_checkout
) values
    ('pri_REPLACE_automation_pro',     'pro',     'one_time', 'topup', 10, 'USD', false, 30, true, 'automation_1000_usd_10', null, 1000, false)
on conflict (paddle_price_id) do nothing;

-- `sku` is unique across the catalogue, and a pack is looked up by sku, so one
-- pack row serves one plan. Pro is where the pool exists to be exceeded; a
-- Starter or Teams pack is a second row with its own sku when it is decided.

create or replace function public.apply_topup_purchase(
    p_user_id uuid,
    p_transaction_id text,
    p_price_id text,
    p_intent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_intent public.topup_checkout_intents%rowtype;
    v_hours numeric;
    v_credits numeric;
    v_pack_plan text;
    v_entitlement jsonb;
    v_subscription public.subscriptions%rowtype;
    v_topup_id uuid;
    v_reason text;
begin
    select * into v_intent
      from public.topup_checkout_intents
     where id = p_intent_id
     for update;
    if not found
       or v_intent.user_id <> p_user_id
       or v_intent.paddle_price_id <> p_price_id then
        return jsonb_build_object('applied', false, 'error', 'invalid_topup_intent');
    end if;
    if v_intent.paddle_transaction_id is not null
       and v_intent.paddle_transaction_id <> p_transaction_id then
        return jsonb_build_object('applied', false, 'error', 'topup_transaction_mismatch');
    end if;

    select id into v_topup_id
      from public.usage_topups
     where paddle_transaction_id = p_transaction_id;
    if v_topup_id is not null then
        return jsonb_build_object('applied', false, 'reason', 'already_applied', 'topup_id', v_topup_id);
    end if;

    -- A pack grants hours or credits; the row says which. The plan comes from
    -- the same row, so a pack is only ever valid for the plan it was listed under.
    select top_up_hours, top_up_credits, plan into v_hours, v_credits, v_pack_plan
      from public.plan_prices
     where paddle_price_id = p_price_id
       and sku = v_intent.sku
       and kind = 'topup'
       and active;
    if v_hours is null and v_credits is null then
        return jsonb_build_object('applied', false, 'error', 'invalid_topup_sku');
    end if;

    select * into v_subscription from public.subscriptions where user_id = p_user_id;
    v_entitlement := public.resolve_entitlement(p_user_id);

    if exists (
        select 1 from public.billing_adjustments a
         where a.paddle_transaction_id = p_transaction_id
           and (
               (a.action = 'refund' and a.status = 'approved')
               or (a.action = 'chargeback' and a.status not in ('rejected', 'reversed'))
           )
    ) then
        v_reason := 'transaction_adjusted_before_fulfilment';
    elsif v_intent.status = 'canceled' then
        v_reason := 'checkout_intent_canceled';
    elsif v_intent.expires_at <= now() then
        v_reason := 'checkout_intent_expired';
    elsif v_subscription.user_id is null
       or v_subscription.plan is distinct from v_pack_plan
       or v_subscription.status <> 'active'
       or v_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id then
        v_reason := 'subscription_changed_before_payment';
    elsif (v_entitlement->>'usage_period_start')::timestamptz is distinct from v_intent.period_start
       or (v_entitlement->>'usage_period_end')::timestamptz is distinct from v_intent.period_end then
        v_reason := 'billing_period_changed_before_payment';
    end if;

    insert into public.usage_topups (
        user_id, paddle_transaction_id, paddle_price_id, hours, credits, included_seconds,
        period_start, period_end, status, refund_reason
    ) values (
        p_user_id, p_transaction_id, p_price_id, v_hours, v_credits, v_intent.included_seconds,
        v_intent.period_start, v_intent.period_end,
        case when v_reason is null then 'active' else 'review_required' end,
        v_reason
    )
    on conflict (paddle_transaction_id) do nothing
    returning id into v_topup_id;

    if v_topup_id is null then
        select id into v_topup_id
          from public.usage_topups
         where paddle_transaction_id = p_transaction_id;
        return jsonb_build_object('applied', false, 'reason', 'already_applied', 'topup_id', v_topup_id);
    end if;

    update public.topup_checkout_intents
       set paddle_transaction_id = p_transaction_id,
           status = case when v_reason is null then 'fulfilled' else 'reconciliation_required' end,
           reconciliation_reason = v_reason,
           updated_at = now()
     where id = v_intent.id;

    if v_reason is not null then
        return jsonb_build_object(
            'applied', false,
            'error', 'topup_reconciliation_required',
            'reason', v_reason,
            'topup_id', v_topup_id
        );
    end if;
    return jsonb_build_object('applied', true, 'topup_id', v_topup_id, 'hours', v_hours, 'credits', v_credits);
end;
$$;

revoke all on function public.apply_topup_purchase(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_topup_purchase(uuid, text, text, uuid) to service_role;

create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub              public.subscriptions%rowtype;
    v_org_sub          public.org_subscriptions%rowtype;
    v_org_id           uuid;
    v_plan             public.plans%rowtype;
    v_payer            text;
    v_seats            int;
    v_status           text;
    v_active           boolean;
    v_features         text[];
    v_limits           jsonb;
    v_unlimited        boolean;
    v_window           record;
    v_period_start     timestamptz;
    v_period_end       timestamptz;
    v_renewal          timestamptz;
    v_consumed_seconds numeric;
    v_included_seconds numeric;
    v_top_up_seconds   numeric;
    v_remaining        numeric;
    v_billing_cycle    text;
    v_credits_included numeric;
    v_credits_used     numeric;
    v_credits_top_up   numeric;
    v_credits_left     numeric;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;

    select p.active_org_id into v_org_id
      from public.profiles p where p.user_id = p_user_id;
    if v_org_id is not null then
        select * into v_org_sub from public.org_subscriptions where org_id = v_org_id;
        if not found then
            v_org_sub := null;
        -- `past_due` is deliberately not here. A workspace that has stopped
        -- paying must not answer for a member who pays for themselves.
        elsif v_org_sub.status not in ('trialing', 'active') then
            v_org_sub := null;
        -- A trial that has run out is over, whether or not Paddle said so.
        elsif v_org_sub.status = 'trialing'
              and v_org_sub.current_period_end is not null
              and now() > v_org_sub.current_period_end then
            v_org_sub := null;
        elsif not public.org_seat_is_held(v_org_id, p_user_id) then
            v_org_sub := null;
        end if;
    end if;

    if v_org_sub.org_id is null and v_sub.user_id is null then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'price_id', null,
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'hours_are_unlimited', false,
            'included_seconds', 0, 'top_up_seconds', 0,
            'consumed_seconds', 0, 'remaining_seconds', 0,
            'can_start_meeting', false,
            'integration_credits_included', 0, 'integration_credits_used', 0,
            'integration_credits_remaining', 0, 'can_run_integration_action', false,
            'billing_cycle', null,
            'payer', 'none', 'org_id', null, 'seats', null,
            'trial_ends_at', null, 'renewal_date', null,
            'usage_period_start', null, 'usage_period_end', null
        );
    end if;

    if v_org_sub.org_id is not null then
        v_payer  := 'organization';
        v_seats  := v_org_sub.seats;
        v_status := v_org_sub.status;
        select * into v_plan from public.plans where plan = v_org_sub.plan;
        select billing_cycle into v_billing_cycle
          from public.plan_prices where paddle_price_id = v_org_sub.paddle_price_id;
        -- The trial end is the period end: for a trialing subscription that is
        -- what Paddle's current billing period is.
        select * into v_window from public.monthly_usage_window(
            v_status, v_org_sub.current_period_end,
            v_org_sub.current_period_start, v_org_sub.current_period_end);
        v_limits    := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_org_sub.limit_overrides, '{}'::jsonb);
        -- The workspace's answer, or the member's own if they were sold a promise
        -- the workspace does not make — but only while the subscription carrying
        -- that promise is itself being paid for. A `past_due` card confers
        -- nothing, on either side.
        v_unlimited := coalesce(v_org_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false)
                       or coalesce(v_sub.status in ('trialing', 'active')
                                   and coalesce(v_sub.hours_are_unlimited, false), false);
        -- A grant on the person is additive and survives the organization paying.
        v_features  := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    else
        v_payer  := 'personal';
        v_status := v_sub.status;
        if v_status = 'trialing'
           and v_sub.trial_ends_at is not null
           and now() > v_sub.trial_ends_at then
            v_status := 'expired';
        end if;
        select * into v_plan from public.plans where plan = v_sub.plan;
        -- Read here rather than in the app because a grandfathered price is
        -- hidden from the client catalogue by RLS: without this the paywall can
        -- only tell the PLAN, so it locks both cycle cards as "current" and a
        -- legitimate switch becomes impossible.
        select billing_cycle into v_billing_cycle
          from public.plan_prices where paddle_price_id = v_sub.paddle_price_id;
        select * into v_window from public.monthly_usage_window(
            v_status, v_sub.trial_ends_at, v_sub.current_period_start, v_sub.current_period_end);
        v_limits    := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);
        v_unlimited := coalesce(v_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false);
        v_features  := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    end if;

    v_period_start := v_window.period_start;
    v_period_end   := v_window.period_end;
    v_renewal      := v_window.renewal;
    v_active       := v_status in ('trialing', 'active');

    if v_payer = 'organization' then
        -- Stamped rows are the truth. Unstamped rows predate the stamp and keep
        -- the old attribution until the last live period without one has closed.
        select coalesce(sum(u.audio_seconds), 0) into v_consumed_seconds
        from public.usage_events u
        where u.kind = 'transcribe'
          and u.created_at >= v_period_start
          and u.created_at <  v_period_end
          and (
                u.org_id = v_org_id
                or (u.org_id is null
                    and u.user_id in (select h.user_id from public.org_seat_holders(v_org_id) h))
          );
        v_included_seconds := case
            when v_active then coalesce((v_limits->>'hours_per_month')::numeric, 0) * 3600 * v_seats
            else 0
        end;
        -- Integration rows are only ever written stamped, so the pool has no
        -- fallback to need.
        select count(*) into v_credits_used
        from public.usage_events u
        where u.kind = 'integration'
          and u.org_id = v_org_id
          and u.created_at >= v_period_start
          and u.created_at <  v_period_end;
        v_credits_included := case
            when v_active then coalesce((v_limits->>'integration_credits_per_month')::numeric, 0) * v_seats
            else 0
        end;
        -- A pack is always minted on the personal path, so its pinned window is a
        -- personal subscription's and never equals the workspace's. Overlap is
        -- the only test that can find it.
        select coalesce(sum(hours), 0) * 3600, coalesce(sum(credits), 0)
          into v_top_up_seconds, v_credits_top_up
        from public.usage_topups
        where user_id = p_user_id
          and status = 'active'
          and period_start < v_period_end
          and period_end   > v_period_start
          and now() < period_end;
    else
        -- A personal plan pays for what was charged to the person, which is
        -- everything they did outside a workspace's coverage.
        select coalesce(sum(audio_seconds), 0) into v_consumed_seconds
        from public.usage_events
        where user_id = p_user_id
          and kind = 'transcribe'
          and org_id is null
          and created_at >= v_period_start
          and created_at <  v_period_end;
        v_included_seconds := case
            when v_active then coalesce((v_limits->>'hours_per_month')::numeric, 0) * 3600
            else 0
        end;
        select count(*) into v_credits_used
        from public.usage_events
        where user_id = p_user_id
          and kind = 'integration'
          and org_id is null
          and created_at >= v_period_start
          and created_at <  v_period_end;
        v_credits_included := case
            when v_active then coalesce((v_limits->>'integration_credits_per_month')::numeric, 0)
            else 0
        end;
        select coalesce(sum(hours), 0) * 3600, coalesce(sum(credits), 0)
          into v_top_up_seconds, v_credits_top_up
        from public.usage_topups
        where user_id = p_user_id
          and status = 'active'
          and period_start = v_period_start
          and period_end = v_period_end
          and now() < period_end;
    end if;
    if not v_active then
        v_top_up_seconds := 0;
        v_credits_top_up := 0;
    end if;

    v_remaining    := greatest(v_included_seconds + v_top_up_seconds - v_consumed_seconds, 0);
    v_credits_left := greatest(v_credits_included + v_credits_top_up - v_credits_used, 0);

    return jsonb_build_object(
        'plan', case when v_payer = 'organization'
                     then v_org_sub.plan else coalesce(v_sub.plan, 'none') end,
        'status', v_status,
        'price_id', case when v_payer = 'organization'
                         then v_org_sub.paddle_price_id else v_sub.paddle_price_id end,
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_consumed_seconds / 3600.0, 3),
        'hours_limit', round((v_included_seconds + v_top_up_seconds) / 3600.0, 3),
        'hours_are_unlimited', v_unlimited,
        'included_seconds', round(v_included_seconds),
        'top_up_seconds', round(v_top_up_seconds),
        'consumed_seconds', round(v_consumed_seconds),
        'remaining_seconds', round(v_remaining),
        'can_start_meeting', v_active and (v_unlimited or v_remaining > 0),
        'integration_credits_included', v_credits_included + v_credits_top_up,
        'integration_credits_used', v_credits_used,
        'integration_credits_remaining', v_credits_left,
        'can_run_integration_action', v_active and v_credits_left > 0,
        'billing_cycle', v_billing_cycle,
        'payer', v_payer,
        'org_id', case when v_payer = 'organization' then v_org_id end,
        'seats', v_seats,
        'trial_ends_at', case when v_payer = 'organization' and v_status = 'trialing'
                              then v_org_sub.current_period_end
                              when v_payer = 'organization' then null
                              else v_sub.trial_ends_at end,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;
