-- A workspace buys its credits, and so does everyone else.
--
-- The Automation Pack existed for one plan and one buyer: a person on Pro, from
-- their own Subscription page. Everyone else who could run out — a Starter
-- account, a workspace on Teams — was told by the chat to "add credits" and
-- then shown nowhere to do it. Three things fix that here.
--
-- A pack per plan. `sku` is unique and a pack is looked up by it, so Starter
-- and Teams each get their own row, dark until the Paddle price exists, exactly
-- as Pro's was.
--
-- A workspace intent. `create_topup_checkout_intent` already answers through
-- the resolver; when the resolver says the workspace pays, the intent is the
-- workspace's — pinned to its period and its Paddle subscription, mintable by
-- an owner or admin only — and the pack it fulfils is stamped `org_id` so the
-- workspace's pool, not the buyer's, grows. `apply_topup_purchase` checks the
-- workspace subscription where it checked the personal one. A pack the buyer
-- held before the workspace covered them stays personal and keeps counting by
-- overlap, as before.
--
-- A refund that knows what a credits pack is. `refund_topup_transaction`
-- measured every pack in seconds of audio, which for a pack of credits is the
-- number `null`, and `least(x, null)` is `x`: a refund of an untouched credits
-- pack could be parked for review over audio the pack never granted, and a
-- refund of a spent one went through and left the pool negative. It now
-- measures a pack in the unit it granted, for the payer that holds it.

alter table public.topup_checkout_intents
    add column if not exists org_id uuid references public.organizations(id) on delete cascade;
alter table public.usage_topups
    add column if not exists org_id uuid references public.organizations(id) on delete cascade;

create index if not exists usage_topups_org_period_idx
    on public.usage_topups (org_id, period_start, period_end)
    where status = 'active' and org_id is not null;

create index if not exists usage_events_integration_org_idx
    on public.usage_events (org_id, created_at desc)
    where kind = 'integration' and org_id is not null;

alter table public.topup_checkout_intents
    drop constraint if exists topup_checkout_intents_sku_check;
alter table public.topup_checkout_intents
    add constraint topup_checkout_intents_sku_check
    check (sku in (
        'starter_5h_usd_12', 'pro_10h_usd_29',
        'automation_1000_usd_10', 'starter_automation_1000_usd_10', 'teams_automation_1000_usd_10'
    ));

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, top_up_credits, available_for_new_checkout
) values
    ('pri_REPLACE_automation_starter', 'starter', 'one_time', 'topup', 10, 'USD', false, 31, true, 'starter_automation_1000_usd_10', null, 1000, false),
    ('pri_REPLACE_automation_teams',   'teams',   'one_time', 'topup', 10, 'USD', false, 32, true, 'teams_automation_1000_usd_10',   null, 1000, false)
on conflict (paddle_price_id) do nothing;

create or replace function public.create_topup_checkout_intent(
    p_user_id uuid,
    p_sku text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_entitlement jsonb;
    v_price_id text;
    v_plan text;
    v_org_id uuid;
    v_role text;
    v_subscription_id text;
    v_intent_id uuid;
    v_expires_at timestamptz;
begin
    if p_user_id is null then
        raise exception 'create_topup_checkout_intent requires a user';
    end if;

    -- An unknown sku and a sku whose Paddle price has not been created yet are
    -- the same answer to the caller: there is nothing here to buy.
    select paddle_price_id, plan into v_price_id, v_plan
      from public.plan_prices
     where sku = p_sku
       and billing_cycle = 'one_time'
       and kind = 'topup'
       and active
       and available_for_new_checkout;
    if v_price_id is null or v_price_id like 'pri_REPLACE_%' then
        return jsonb_build_object('created', false, 'error', 'topup_unconfigured');
    end if;

    v_entitlement := public.resolve_entitlement(p_user_id);
    if v_entitlement->>'plan' <> v_plan or v_entitlement->>'status' <> 'active' then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    if v_entitlement->>'payer' = 'organization' then
        -- The workspace is buying. Only somebody who may spend its money mints
        -- the intent; the server refuses the rest whatever the page offered.
        v_org_id := (v_entitlement->>'org_id')::uuid;
        select m.role into v_role
          from public.org_members m
         where m.org_id = v_org_id
           and m.user_id = p_user_id
           and m.status = 'active';
        if v_role is null or v_role not in ('owner', 'admin') then
            return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
        end if;
        select paddle_subscription_id into v_subscription_id
          from public.org_subscriptions
         where org_id = v_org_id
           and plan = v_plan
           and status = 'active';
    else
        select paddle_subscription_id into v_subscription_id
          from public.subscriptions
         where user_id = p_user_id
           and plan = v_plan
           and status = 'active';
    end if;
    if v_subscription_id is null then
        return jsonb_build_object('created', false, 'error', 'topup_not_eligible');
    end if;

    -- Short-lived on purpose: an intent that outlives its billing period would
    -- credit a month the customer never paid for.
    v_expires_at := least(now() + interval '1 hour', (v_entitlement->>'usage_period_end')::timestamptz);
    if v_expires_at <= now() then
        return jsonb_build_object('created', false, 'error', 'no_active_usage_period');
    end if;

    insert into public.topup_checkout_intents (
        user_id, org_id, paddle_subscription_id, paddle_price_id, sku,
        period_start, period_end, included_seconds, expires_at
    ) values (
        p_user_id, v_org_id, v_subscription_id, v_price_id, p_sku,
        (v_entitlement->>'usage_period_start')::timestamptz,
        (v_entitlement->>'usage_period_end')::timestamptz,
        coalesce((v_entitlement->>'included_seconds')::numeric, 0),
        v_expires_at
    ) returning id into v_intent_id;

    return jsonb_build_object(
        'created', true,
        'intent_id', v_intent_id,
        'org_id', v_org_id,
        'paddle_price_id', v_price_id,
        'expires_at', v_expires_at
    );
end;
$$;

revoke all on function public.create_topup_checkout_intent(uuid, text) from public, anon, authenticated;
grant execute on function public.create_topup_checkout_intent(uuid, text) to service_role;

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
    v_org_subscription public.org_subscriptions%rowtype;
    v_subscription_changed boolean;
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

    v_entitlement := public.resolve_entitlement(p_user_id);

    -- The subscription the intent was pinned to has to still be the one being
    -- paid for: the workspace's when the workspace bought, the person's otherwise.
    if v_intent.org_id is not null then
        select * into v_org_subscription from public.org_subscriptions where org_id = v_intent.org_id;
        v_subscription_changed := v_org_subscription.org_id is null
            or v_org_subscription.plan is distinct from v_pack_plan
            or v_org_subscription.status <> 'active'
            or v_org_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id
            or (v_entitlement->>'org_id') is distinct from v_intent.org_id::text;
    else
        select * into v_subscription from public.subscriptions where user_id = p_user_id;
        v_subscription_changed := v_subscription.user_id is null
            or v_subscription.plan is distinct from v_pack_plan
            or v_subscription.status <> 'active'
            or v_subscription.paddle_subscription_id is distinct from v_intent.paddle_subscription_id;
    end if;

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
    elsif v_subscription_changed then
        v_reason := 'subscription_changed_before_payment';
    elsif (v_entitlement->>'usage_period_start')::timestamptz is distinct from v_intent.period_start
       or (v_entitlement->>'usage_period_end')::timestamptz is distinct from v_intent.period_end then
        v_reason := 'billing_period_changed_before_payment';
    end if;

    insert into public.usage_topups (
        user_id, org_id, paddle_transaction_id, paddle_price_id, hours, credits, included_seconds,
        period_start, period_end, status, refund_reason
    ) values (
        p_user_id, v_intent.org_id, p_transaction_id, p_price_id, v_hours, v_credits, v_intent.included_seconds,
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

create or replace function public.refund_topup_transaction(
    p_transaction_id text,
    p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_topup public.usage_topups%rowtype;
    v_consumed numeric;
    v_prior numeric;
    v_included numeric;
    v_granted numeric;
    v_consumed_from_topup numeric;
begin
    select * into v_topup
      from public.usage_topups
     where paddle_transaction_id = p_transaction_id
     for update;
    if not found then
        return jsonb_build_object('action', 'noop');
    end if;
    if v_topup.status <> 'active' then
        return jsonb_build_object('action', v_topup.status);
    end if;

    -- Measured in the unit the pack granted, over the pool it was added to:
    -- the workspace's when the workspace bought it, the person's otherwise.
    if v_topup.credits is not null then
        v_granted := v_topup.credits;
        if v_topup.org_id is not null then
            select count(*) into v_consumed
              from public.usage_events u
             where u.kind = 'integration'
               and u.org_id = v_topup.org_id
               and u.created_at >= v_topup.period_start
               and u.created_at < v_topup.period_end;
            select coalesce((coalesce(p.limits, '{}'::jsonb) || coalesce(s.limit_overrides, '{}'::jsonb)
                              ->>'integration_credits_per_month')::numeric, 0) * s.seats
              into v_included
              from public.org_subscriptions s
              join public.plans p on p.plan = s.plan
             where s.org_id = v_topup.org_id;
        else
            select count(*) into v_consumed
              from public.usage_events u
             where u.kind = 'integration'
               and u.user_id = v_topup.user_id
               and u.org_id is null
               and u.created_at >= v_topup.period_start
               and u.created_at < v_topup.period_end;
            select coalesce((coalesce(p.limits, '{}'::jsonb) || coalesce(s.limit_overrides, '{}'::jsonb)
                              ->>'integration_credits_per_month')::numeric, 0)
              into v_included
              from public.subscriptions s
              join public.plans p on p.plan = s.plan
             where s.user_id = v_topup.user_id;
        end if;
        select coalesce(sum(t.credits), 0) into v_prior
          from public.usage_topups t
         where t.status = 'active'
           and t.credits is not null
           and t.period_start = v_topup.period_start
           and t.period_end = v_topup.period_end
           and t.org_id is not distinct from v_topup.org_id
           and (t.org_id is not null or t.user_id = v_topup.user_id)
           and (t.created_at, t.id) < (v_topup.created_at, v_topup.id);
    else
        v_granted := v_topup.hours * 3600;
        v_included := v_topup.included_seconds;
        if v_topup.org_id is not null then
            select coalesce(sum(u.audio_seconds), 0) into v_consumed
              from public.usage_events u
             where u.kind = 'transcribe'
               and u.org_id = v_topup.org_id
               and u.created_at >= v_topup.period_start
               and u.created_at < v_topup.period_end;
        else
            select coalesce(sum(u.audio_seconds), 0) into v_consumed
              from public.usage_events u
             where u.user_id = v_topup.user_id
               and u.kind = 'transcribe'
               and u.org_id is null
               and u.created_at >= v_topup.period_start
               and u.created_at < v_topup.period_end;
        end if;
        -- Packs are consumed in purchase order, so an earlier pack absorbs
        -- overage before this one does.
        select coalesce(sum(t.hours), 0) * 3600 into v_prior
          from public.usage_topups t
         where t.status = 'active'
           and t.hours is not null
           and t.period_start = v_topup.period_start
           and t.period_end = v_topup.period_end
           and t.org_id is not distinct from v_topup.org_id
           and (t.org_id is not null or t.user_id = v_topup.user_id)
           and (t.created_at, t.id) < (v_topup.created_at, v_topup.id);
    end if;

    v_consumed_from_topup := greatest(
        least(v_consumed - coalesce(v_included, 0) - v_prior, v_granted),
        0
    );

    if v_consumed_from_topup > 0 then
        update public.usage_topups
           set status = 'review_required',
               refund_reason = p_reason
         where id = v_topup.id;
        return jsonb_build_object(
            'action', 'review_required',
            'consumed', v_consumed_from_topup,
            'unit', case when v_topup.credits is not null then 'credits' else 'seconds' end
        );
    end if;

    update public.usage_topups
       set status = 'refunded',
           refunded_at = now(),
           refund_reason = p_reason
     where id = v_topup.id;
    return jsonb_build_object('action', 'refunded');
end;
$$;

revoke all on function public.refund_topup_transaction(text, text) from public, anon, authenticated;
grant execute on function public.refund_topup_transaction(text, text) to service_role;

create or replace function public.org_billing_overview(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub        public.org_subscriptions%rowtype;
    v_plan       public.plans%rowtype;
    v_window     record;
    v_status     text;
    v_consumed   numeric;
    v_included   numeric;
    v_limits     jsonb;
    v_credits_included numeric;
    v_credits_used     numeric;
    v_credits_top_up   numeric;
    v_members    jsonb;
    v_role       text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select m.role into v_role
      from public.org_members m
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active';
    if v_role is null then
        raise exception 'not a member of this organization' using errcode = '42501';
    end if;

    select * into v_sub from public.org_subscriptions where org_id = p_org_id;
    if not found then
        return jsonb_build_object('has_subscription', false, 'viewer_role', v_role);
    end if;

    -- The page says the trial is over even when Paddle has not yet said so,
    -- exactly as the resolver stops honouring it.
    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.current_period_end is not null
       and now() > v_sub.current_period_end then
        v_status := 'expired';
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;
    select * into v_window from public.monthly_usage_window(
        v_status, v_sub.current_period_end, v_sub.current_period_start, v_sub.current_period_end);

    -- The same attribution the resolver uses, so the page and the gate agree.
    select coalesce(sum(u.audio_seconds), 0) into v_consumed
      from public.usage_events u
     where u.kind = 'transcribe'
       and u.created_at >= v_window.period_start
       and u.created_at <  v_window.period_end
       and (
             u.org_id = p_org_id
             or (u.org_id is null
                 and u.user_id in (select h.user_id from public.org_seat_holders(p_org_id) h))
       );

    v_limits := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);
    v_included := case
        when v_status in ('trialing', 'active')
        then coalesce((v_limits->>'hours_per_month')::numeric, 0) * 3600 * v_sub.seats
        else 0
    end;

    -- The same pool the resolver gates on, so the page and the refusal agree.
    select count(*) into v_credits_used
      from public.usage_events u
     where u.kind = 'integration'
       and u.org_id = p_org_id
       and u.created_at >= v_window.period_start
       and u.created_at <  v_window.period_end;
    v_credits_included := case
        when v_status in ('trialing', 'active')
        then coalesce((v_limits->>'integration_credits_per_month')::numeric, 0) * v_sub.seats
        else 0
    end;
    select coalesce(sum(credits), 0) into v_credits_top_up
      from public.usage_topups
     where org_id = p_org_id
       and status = 'active'
       and period_start = v_window.period_start
       and period_end = v_window.period_end
       and now() < period_end
       and v_status in ('trialing', 'active');

    select coalesce(jsonb_agg(row_to_json(entry)::jsonb order by entry.seat), '[]'::jsonb)
      into v_members
      from (
        select m.user_id,
               coalesce(p.display_name, u.email) as name,
               u.email,
               m.role,
               row_number() over (order by m.joined_at, m.id) as seat,
               row_number() over (order by m.joined_at, m.id) <= v_sub.seats as holds_seat
          from public.org_members m
          join auth.users u on u.id = m.user_id
          left join public.profiles p on p.user_id = m.user_id
         where m.org_id = p_org_id
           and m.status = 'active'
      ) entry;

    return jsonb_build_object(
        'has_subscription', true,
        'viewer_role', v_role,
        'plan', v_sub.plan,
        'status', v_status,
        'seats', v_sub.seats,
        'billing_cycle', (select billing_cycle from public.plan_prices
                           where paddle_price_id = v_sub.paddle_price_id),
        'hours_included', round(v_included / 3600.0, 3),
        'hours_used', round(v_consumed / 3600.0, 3),
        'integration_credits_included', v_credits_included + v_credits_top_up,
        'integration_credits_used', v_credits_used,
        'trial_ends_at', case when v_status = 'trialing' then v_sub.current_period_end end,
        'renewal_date', v_window.renewal,
        'usage_period_start', v_window.period_start,
        'usage_period_end', v_window.period_end,
        'members', v_members
    );
end;
$$;

revoke all on function public.org_billing_overview(uuid) from public, anon;
grant execute on function public.org_billing_overview(uuid) to authenticated, service_role;

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
        -- The workspace's own packs are pinned to its window. A pack the person
        -- bought before the workspace covered them was pinned to a personal
        -- window, and overlap is the only test that can find it.
        select coalesce(sum(hours), 0) * 3600, coalesce(sum(credits), 0)
          into v_top_up_seconds, v_credits_top_up
        from public.usage_topups
        where status = 'active'
          and now() < period_end
          and (
                (org_id = v_org_id
                 and period_start = v_period_start
                 and period_end = v_period_end)
                or (org_id is null
                    and user_id = p_user_id
                    and period_start < v_period_end
                    and period_end   > v_period_start)
          );
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
          and org_id is null
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
