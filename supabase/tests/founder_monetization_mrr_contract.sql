begin;

-- MRR is money Paddle is billing for an active subscription at a price the
-- catalogue knows. Everything else — past due, trial, manual access, a price
-- the catalogue has lost, a one-time pack — is reported in its own bucket and
-- never folded into `mrr_usd`.

insert into auth.users (id, email, created_at, updated_at)
values
    ('20000000-0000-4000-8000-000000000301', 'vlad@hellonod.app', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000311', 'active-monthly@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000312', 'active-yearly@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000313', 'past-due@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000314', 'manual-access@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000315', 'retired-price@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000316', 'paddle-trial@example.invalid', now() - interval '5 days', now()),
    ('20000000-0000-4000-8000-000000000317', 'canceled@example.invalid', now() - interval '200 days', now()),
    ('20000000-0000-4000-8000-000000000318', 'pack-buyer@example.invalid', now() - interval '200 days', now());

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, available_for_new_checkout
)
values
    ('pri_mrr_test_pro_monthly',  'pro',     'monthly',  'subscription', 29, 'USD', false, 910, true, 'mrr_test_pro_monthly_usd_29', null, true),
    ('pri_mrr_test_pro_yearly',   'pro',     'yearly',   'subscription', 24, 'USD', false, 911, true, 'mrr_test_pro_yearly_usd_288', null, true),
    ('pri_mrr_test_starter_pack', 'starter', 'one_time', 'topup',        12, 'USD', false, 912, true, 'mrr_test_starter_5h_usd_12',  5,    true)
on conflict (paddle_price_id) do nothing;

create or replace function pg_temp.seed_sub(
    p_user uuid, p_plan text, p_status text, p_price text, p_paddle_sub text,
    p_trial_ends timestamptz default null
) returns void language sql as $seed$
    insert into public.subscriptions (
        user_id, plan, status, converted_at, current_period_start, current_period_end,
        paddle_price_id, paddle_subscription_id, paddle_customer_id, trial_ends_at
    )
    values (p_user, p_plan, p_status, now() - interval '60 days',
            date_trunc('month', now()), date_trunc('month', now()) + interval '1 month',
            p_price, p_paddle_sub, case when p_paddle_sub is null then null else 'ctm_' || p_paddle_sub end,
            p_trial_ends)
    on conflict (user_id) do update set
        plan = excluded.plan, status = excluded.status, converted_at = excluded.converted_at,
        current_period_start = excluded.current_period_start,
        current_period_end = excluded.current_period_end,
        paddle_price_id = excluded.paddle_price_id,
        paddle_subscription_id = excluded.paddle_subscription_id,
        paddle_customer_id = excluded.paddle_customer_id,
        trial_ends_at = excluded.trial_ends_at;
$seed$;

-- Two Paddle-billed, catalogue-priced, active subscriptions: 29 + 24 = 53.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000311', 'pro', 'active',   'pri_mrr_test_pro_monthly', 'sub_mrr_monthly');
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000312', 'pro', 'active',   'pri_mrr_test_pro_yearly',  'sub_mrr_yearly');
-- A failed charge is not revenue.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000313', 'pro', 'past_due', 'pri_mrr_test_pro_monthly', 'sub_mrr_past_due');
-- Access granted by hand: no Paddle subscription behind it.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000314', 'pro', 'active',   null, null);
-- Paddle bills it, but the price id is one the catalogue no longer has.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000315', 'pro', 'active',   'pri_mrr_test_gone', 'sub_mrr_retired');
-- A Paddle trial that has not converted yet.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000316', 'pro', 'trialing', 'pri_mrr_test_pro_monthly', 'sub_mrr_trial', now() + interval '9 days');
-- Churned.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000317', 'pro', 'canceled', 'pri_mrr_test_pro_monthly', 'sub_mrr_canceled');

-- A pack bought this month, and one refunded: only the live one is cash.
insert into public.usage_topups (
    user_id, paddle_transaction_id, paddle_price_id, hours, included_seconds,
    period_start, period_end, status, created_at
) values
    ('20000000-0000-4000-8000-000000000318', 'txn_mrr_pack_live', 'pri_mrr_test_starter_pack', 5, 18000,
     date_trunc('month', now()), date_trunc('month', now()) + interval '1 month', 'active', now() - interval '2 days'),
    ('20000000-0000-4000-8000-000000000318', 'txn_mrr_pack_refund', 'pri_mrr_test_starter_pack', 5, 18000,
     date_trunc('month', now()), date_trunc('month', now()) + interval '1 month', 'refunded', now() - interval '3 days');

-- A pack bought for a workspace is the organization's money, not personal.
insert into public.organizations (id, name, slug, created_by)
values ('21000000-0000-4000-8000-000000000001', 'MRR Co', 'mrr-co', '20000000-0000-4000-8000-000000000318');
insert into public.usage_topups (
    user_id, org_id, paddle_transaction_id, paddle_price_id, hours, included_seconds,
    period_start, period_end, status, created_at
) values
    ('20000000-0000-4000-8000-000000000318', '21000000-0000-4000-8000-000000000001', 'txn_mrr_pack_org',
     'pri_mrr_test_starter_pack', 5, 18000,
     date_trunc('month', now()), date_trunc('month', now()) + interval '1 month', 'active', now() - interval '1 day');

-- Manual access granted this month must not read as a new paying customer.
update public.subscriptions set converted_at = now() - interval '3 days'
 where user_id = '20000000-0000-4000-8000-000000000314';

-- The founder's own paid subscription must not count anywhere.
select pg_temp.seed_sub('20000000-0000-4000-8000-000000000301', 'pro', 'active', 'pri_mrr_test_pro_monthly', 'sub_mrr_founder');

-- Whatever else the local database holds is measured first, so the assertions
-- below are about the rows seeded here and nothing else.
create temp table baseline as
select
    coalesce(sum(pp.display_amount) filter (
        where s.status = 'active' and s.paddle_subscription_id is not null), 0) as mrr,
    count(*) filter (
        where s.status = 'active' and s.paddle_subscription_id is not null and pp.paddle_price_id is not null) as mrr_subs,
    count(*) filter (
        where s.status = 'active' and s.paddle_subscription_id is not null and pp.paddle_price_id is null) as unpriced,
    coalesce(sum(pp.display_amount) filter (where s.status = 'past_due' and s.paddle_subscription_id is not null), 0) as past_due,
    count(*) filter (where s.status = 'past_due' and s.paddle_subscription_id is not null) as past_due_subs,
    count(*) filter (where s.status in ('active', 'past_due') and s.paddle_subscription_id is not null
                       and s.converted_at > now() - interval '30 days') as new_paying,
    count(*) filter (where s.status in ('active', 'past_due') and s.paddle_subscription_id is null) as manual,
    coalesce(sum(pp.display_amount) filter (
        where s.status = 'trialing' and s.paddle_subscription_id is not null
          and (s.trial_ends_at is null or s.trial_ends_at > now())), 0) as trialing
from public.subscriptions s
left join public.plan_prices pp on pp.paddle_price_id = s.paddle_price_id and pp.kind = 'subscription'
where s.user_id not in (select id from auth.users where lower(email) = any (public._excluded_emails()))
  and s.user_id not in (
    '20000000-0000-4000-8000-000000000311', '20000000-0000-4000-8000-000000000312',
    '20000000-0000-4000-8000-000000000313', '20000000-0000-4000-8000-000000000314',
    '20000000-0000-4000-8000-000000000315', '20000000-0000-4000-8000-000000000316',
    '20000000-0000-4000-8000-000000000317');

create temp table baseline_topups as
select coalesce(sum(pp.display_amount), 0) as cash
from public.usage_topups t
join public.plan_prices pp on pp.paddle_price_id = t.paddle_price_id
where t.status = 'active' and t.org_id is null and t.created_at > now() - interval '30 days'
  and t.user_id <> '20000000-0000-4000-8000-000000000318'
  and t.user_id not in (select id from auth.users where lower(email) = any (public._excluded_emails()));

set local role authenticated;
set local request.jwt.claims = '{"sub":"20000000-0000-4000-8000-000000000301","email":"vlad@hellonod.app","role":"authenticated"}';

create temp table result as select public.founder_monetization() as m;

reset role;

do $$
declare
    r jsonb := (select m from result);
    b record := (select b from baseline b);
    pack numeric := (select cash from baseline_topups);
begin
    if (r->>'mrr_usd')::numeric <> b.mrr + 53 then
        raise exception 'mrr_usd must be the two active Paddle subscriptions only: % (baseline %)', r->>'mrr_usd', b.mrr;
    end if;
    if (r->>'mrr_subscriptions')::bigint <> b.mrr_subs + 2 then
        raise exception 'mrr_subscriptions must count the two priced active rows: %', r->>'mrr_subscriptions';
    end if;
    if (r->>'mrr_unpriced_subscriptions')::bigint <> b.unpriced + 1 then
        raise exception 'the retired price must be reported as unpriced, not guessed: %', r->>'mrr_unpriced_subscriptions';
    end if;
    if (r->>'past_due_mrr_usd')::numeric <> b.past_due + 29 or (r->>'past_due_subscriptions')::bigint <> b.past_due_subs + 1 then
        raise exception 'past_due must sit in its own bucket: % / %', r->>'past_due_mrr_usd', r->>'past_due_subscriptions';
    end if;
    if (r->>'new_paying_30d')::bigint <> b.new_paying then
        raise exception 'new_paying_30d must count Paddle conversions only: % (baseline %)', r->>'new_paying_30d', b.new_paying;
    end if;
    if (r->>'manual_access_subscriptions')::bigint <> b.manual + 1 then
        raise exception 'manual access must be counted, not billed: %', r->>'manual_access_subscriptions';
    end if;
    if (r->>'trialing_mrr_usd')::numeric <> b.trialing + 29 then
        raise exception 'a Paddle trial is pipeline, not MRR: %', r->>'trialing_mrr_usd';
    end if;
    if (r->>'topup_revenue_30d_usd')::numeric <> pack + 12 then
        raise exception 'only the live personal pack is cash: %', r->>'topup_revenue_30d_usd';
    end if;
    if (r->>'arr_usd')::numeric <> ((r->>'mrr_usd')::numeric * 12) then
        raise exception 'arr must be 12 × mrr';
    end if;
    if (r->>'arpu_usd')::numeric <> round((r->>'mrr_usd')::numeric / (r->>'mrr_subscriptions')::numeric, 2) then
        raise exception 'arpu must divide mrr by the subscriptions that make it up: %', r->>'arpu_usd';
    end if;
    -- The old definition, recomputed here so the gap between the two is a
    -- number and not a story: every active/past_due row at catalogue price,
    -- a guessed monthly list price when the lookup missed.
    if (r->>'mrr_usd')::numeric >= (
        select coalesce(sum(coalesce(
            (select pp.display_amount from public.plan_prices pp where pp.paddle_price_id = s.paddle_price_id),
            (select pp.display_amount from public.plan_prices pp
              where pp.plan = s.plan and pp.kind = 'subscription' and pp.billing_cycle = 'monthly' and pp.active
              order by pp.sort_order limit 1))), 0)
        from public.subscriptions s
        where s.status in ('active', 'past_due')
          and s.user_id <> all (public._excluded_user_ids()))
    then
        raise exception 'the corrected mrr must be strictly below the old definition on this seed';
    end if;
end $$;

rollback;
