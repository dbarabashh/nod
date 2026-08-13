create or replace function public.enqueue_activation_conversion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_signup_at timestamptz;
    v_touch_id uuid;
    v_ga_client_id text;
begin
    if new.deleted_at is not null or new.ended_at <= new.started_at then
        return new;
    end if;

    if tg_op = 'UPDATE'
       and old.deleted_at is null
       and old.ended_at > old.started_at then
        return new;
    end if;

    select created_at into v_signup_at from auth.users where id = new.user_id;
    if new.ended_at > v_signup_at + interval '7 days' then
        return new;
    end if;

    select ua.last_touch_id, t.ga_client_id
      into v_touch_id, v_ga_client_id
      from public.user_acquisition ua
      left join public.acquisition_touches t on t.id = ua.last_touch_id
     where ua.user_id = new.user_id
       and ua.coverage_status = 'attributed';

    if exists (
        select 1
          from public.acquisition_touches t
          join public.acquisition_consent_revocations r on r.visitor_id = t.visitor_id
         where t.id = v_touch_id
    ) then
        return new;
    end if;

    if v_touch_id is not null then
        insert into public.google_conversion_outbox (
            user_id, event, occurred_at, touch_id, ga_client_id
        ) values (
            new.user_id, 'activated', new.ended_at, v_touch_id, v_ga_client_id
        )
        on conflict (user_id, event) do nothing;
    end if;

    return new;
end;
$$;

create or replace function public.founder_onboarding_activation(
    p_days integer default 30,
    p_platform text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_window_days integer := greatest(1, least(p_days, 365));
    v_since timestamptz := now() - make_interval(days => v_window_days);
    v_result jsonb;
begin
    perform public._assert_founder();

    with signup_cohort as (
        select u.id as user_id, u.created_at as signed_up_at
        from auth.users u
        where u.created_at >= v_since
          and u.id <> all(v_excluded)
          and (p_platform is null or exists (
              select 1
              from public.user_client_versions cv
              where cv.user_id = u.id and cv.platform = p_platform
          ))
    ), cohort_progress as (
        select c.user_id,
               exists (
                   select 1 from public.product_events pe
                   where pe.user_id = c.user_id
                     and pe.event = 'capture_started'
                     and pe.occurred_at >= c.signed_up_at
                     and (p_platform is null or pe.platform = p_platform)
               ) as captured,
               (
                   select min(m.ended_at)
                   from public.meetings m
                   where m.user_id = c.user_id
                     and m.deleted_at is null
                     and m.ended_at > m.started_at
                     and m.ended_at >= c.signed_up_at
                     and (p_platform is null or m.source_platform = p_platform)
               ) as first_meeting_at
        from signup_cohort c
    ), cohort_activation as (
        select p.*,
               p.first_meeting_at is not null as completed_first_meeting,
               case when p.first_meeting_at is null then false else exists (
                   select 1
                   from public.meetings m
                   where m.user_id = p.user_id
                     and m.deleted_at is null
                     and m.ended_at > m.started_at
                     and m.ended_at > p.first_meeting_at
                     and m.ended_at <= p.first_meeting_at + interval '3 days'
                     and (p_platform is null or m.source_platform = p_platform)
               ) end as completed_second_meeting
        from cohort_progress p
    )
    select jsonb_build_object(
        'window_days', v_window_days,
        'platform', p_platform,
        'cohort_definition', 'signed_up_in_window',
        'events', coalesce((
            select jsonb_agg(to_jsonb(rows) order by rows.count desc)
            from (
                select oe.event, oe.step as stage, count(*) as count,
                       count(distinct coalesce(oe.user_id::text, oe.installation_id::text)) as people
                from public.onboarding_events oe
                where oe.occurred_at >= v_since
                  and (p_platform is null or oe.platform = p_platform)
                  and (oe.user_id is null or oe.user_id <> all(v_excluded))
                group by oe.event, oe.step
            ) rows
        ), '[]'::jsonb),
        'activation', jsonb_build_object(
            'signups', count(*),
            'capture_started', count(*) filter (where captured),
            'first_meeting', count(*) filter (where completed_first_meeting),
            'second_meeting_within_three_days', count(*) filter (where completed_second_meeting)
        ),
        'generated_at', now()
    ) into v_result
    from cohort_activation;

    return v_result;
end;
$$;

create or replace function public.founder_allowance_funnel(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    excl uuid[] := public._excluded_user_ids();
    window_days integer := greatest(coalesce(p_days, 30), 1);
    since timestamptz := now() - make_interval(days => window_days);
    gate_views bigint := 0;
    gate_users bigint := 0;
    topup_clicks bigint := 0;
    upgrade_clicks bigint := 0;
    dismissals bigint := 0;
    failures bigint := 0;
    checkouts bigint := 0;
    purchases bigint := 0;
    first_event timestamptz;
    hours_bought numeric := 0;
    revenue numeric := 0;
    review_required bigint := 0;
    refunded bigint := 0;
    packs_active bigint := 0;
    starter_active bigint := 0;
begin
    perform public._assert_founder();

    select
        count(*) filter (where pe.event = 'allowance_gate_viewed'),
        count(distinct pe.user_id) filter (where pe.event = 'allowance_gate_viewed'),
        count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'success'),
        count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'granted'),
        count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'cancelled'),
        count(*) filter (where pe.event = 'allowance_gate_action' and pe.properties ->> 'outcome' = 'failure'),
        count(*) filter (where pe.event = 'topup_checkout_started'),
        min(pe.occurred_at)
    into gate_views, gate_users, topup_clicks, upgrade_clicks, dismissals, failures,
         checkouts, first_event
    from public.product_events pe
    where pe.occurred_at >= since
      and pe.user_id <> all(excl)
      and pe.event in ('allowance_gate_viewed', 'allowance_gate_action', 'topup_checkout_started');

    select count(*) into starter_active
    from public.subscriptions s
    where s.plan = 'starter' and s.status = 'active' and s.user_id <> all(excl);

    select
        count(*) filter (where t.status in ('active', 'refunded')),
        coalesce(sum(t.hours) filter (where t.status = 'active'), 0),
        coalesce(sum(coalesce(pp.display_amount, 0)) filter (where t.status = 'active'), 0),
        count(*) filter (where t.status = 'review_required'),
        count(*) filter (where t.status = 'refunded'),
        count(*) filter (where t.status = 'active' and now() < t.period_end)
    into purchases, hours_bought, revenue, review_required, refunded, packs_active
    from public.usage_topups t
    left join public.plan_prices pp on pp.paddle_price_id = t.paddle_price_id
    where t.created_at >= since and t.user_id <> all(excl);

    return jsonb_build_object(
        'window_days', window_days,
        'schema_ready', true,
        'first_event_at', first_event,
        'starter_active', starter_active,
        'gate_views', gate_views,
        'gate_users', gate_users,
        'topup_clicks', topup_clicks,
        'upgrade_clicks', upgrade_clicks,
        'dismissals', dismissals,
        'failures', failures,
        'checkouts_started', checkouts,
        'purchases', purchases,
        'purchase_source', 'usage_topups',
        'packs_active', packs_active,
        'hours_bought', hours_bought,
        'revenue_usd', round(revenue, 2),
        'review_required', review_required,
        'refunded', refunded
    );
end;
$$;

create or replace function public.founder_referral_funnel()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
    with assertion as (
        select public._assert_founder()
    ), excluded as (
        select public._excluded_user_ids() as ids
    ), referral_counts as (
        select
            count(*) as attributed,
            count(*) filter (where r.status in ('activated', 'earned', 'rewarded')) as activated,
            count(*) filter (where r.status in ('earned', 'rewarded')) as earned,
            count(*) filter (where r.status = 'rewarded') as rewarded,
            count(*) filter (where r.status = 'expired') as expired,
            count(*) filter (where r.status = 'canceled') as canceled
        from public.referrals r, excluded e, assertion
        where r.referrer_user_id <> all(e.ids) and r.referee_user_id <> all(e.ids)
    ), credit_counts as (
        select
            count(*) filter (where c.status = 'pending') as pending,
            count(*) filter (where c.status = 'payout_pending') as payout_pending,
            count(*) filter (where c.status = 'applied') as applied,
            count(*) filter (where c.status = 'expired') as expired,
            count(*) filter (where c.status = 'canceled') as canceled,
            coalesce(sum(c.cap_units) filter (where c.status in ('pending', 'payout_pending')), 0) as outstanding
        from public.reward_credits c, excluded e
        where c.beneficiary_user_id <> all(e.ids)
    ), payout_counts as (
        select
            count(*) filter (where p.status = 'pending') as pending,
            count(*) filter (where p.status = 'applied') as applied,
            count(*) filter (where p.status = 'reconciliation_required') as stuck
        from public.reward_payouts p, excluded e
        where p.beneficiary_user_id <> all(e.ids)
    )
    select jsonb_build_object(
        'schema_ready', true,
        'codes_minted', (select count(*) from public.referral_codes rc, excluded e where rc.user_id <> all(e.ids)),
        'attributed', r.attributed,
        'activated', r.activated,
        'earned', r.earned,
        'rewarded', r.rewarded,
        'stage_semantics', 'cumulative',
        'expired', r.expired,
        'canceled', r.canceled,
        'credits_pending', c.pending,
        'credits_payout_pending', c.payout_pending,
        'credits_applied', c.applied,
        'credits_expired', c.expired,
        'credits_canceled', c.canceled,
        'outstanding_cap_units', c.outstanding,
        'payouts_pending', p.pending,
        'payouts_applied', p.applied,
        'payouts_stuck', p.stuck,
        'fraud_blocks', (select count(*) from public.referral_fraud_blocks b, excluded e where b.user_id <> all(e.ids))
    )
    from referral_counts r, credit_counts c, payout_counts p;
$$;

revoke all on function public.founder_onboarding_activation(integer, text) from public, anon;
revoke all on function public.founder_allowance_funnel(integer) from public, anon;
revoke all on function public.founder_referral_funnel() from public, anon;
grant execute on function public.founder_onboarding_activation(integer, text) to authenticated;
grant execute on function public.founder_allowance_funnel(integer) to authenticated;
grant execute on function public.founder_referral_funnel() to authenticated;
