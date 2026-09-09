begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('10000000-0000-4000-8000-000000000201', 'vlad@hellonod.app', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000211', 'paid@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000212', 'retired-price@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000213', 'overrun-trial@example.invalid', now() - interval '40 days', now()),
    ('10000000-0000-4000-8000-000000000214', 'expired@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000215', 'cancelled-no-term@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000216', 'no-price-id@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000217', 'paid-and-silent@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000218', 'workspace-user@example.invalid', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000219', 'reactivated@example.invalid', now() - interval '200 days', now());

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, available_for_new_checkout
)
values
    ('pri_test_starter_monthly', 'starter', 'monthly', 'subscription', 15, 'USD', false, 900, true, 'test_starter_monthly_usd_15', true)
on conflict (paddle_price_id) do nothing;

create or replace function pg_temp.seed_sub(
    p_user uuid, p_plan text, p_status text, p_converted timestamptz,
    p_period_start timestamptz, p_period_end timestamptz, p_price text
) returns void language sql as $seed$
    insert into public.subscriptions (
        user_id, plan, status, converted_at, current_period_start, current_period_end, paddle_price_id
    )
    values (p_user, p_plan, p_status, p_converted, p_period_start, p_period_end, p_price)
    on conflict (user_id) do update set
        plan = excluded.plan, status = excluded.status, converted_at = excluded.converted_at,
        current_period_start = excluded.current_period_start,
        current_period_end = excluded.current_period_end,
        paddle_price_id = excluded.paddle_price_id;
$seed$;

-- Converted at the start of THIS month, so every earlier month in the series
-- must carry no revenue at all.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000211', 'starter', 'active',
    date_trunc('month', now()), date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month', 'pri_test_starter_monthly');

-- A price id the catalogue no longer lists.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000212', 'starter', 'active',
    date_trunc('month', now()) - interval '1 month', date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month', 'pri_test_retired_and_gone');

-- Lapsed three months ago: must stop billing after the term it paid for.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000214', 'starter', 'expired',
    now() - interval '200 days', now() - interval '120 days', now() - interval '90 days',
    'pri_test_starter_monthly');

-- Cancelled, and Paddle never sent a term end.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000215', 'starter', 'canceled',
    now() - interval '200 days', now() - interval '200 days', null, 'pri_test_starter_monthly');

-- Converted with no price id at all: the number can only be a guess.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000216', 'starter', 'active',
    now() - interval '200 days', date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month', null);

-- Paid, and has not touched the product in the window.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000217', 'pro', 'active',
    now() - interval '100 days', date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month', null);

-- Converted five months ago, churned, and re-subscribed this month. Only this
-- month was actually paid for; the months between must not read as fact.
select pg_temp.seed_sub('10000000-0000-4000-8000-000000000219', 'pro', 'active',
    date_trunc('month', now()) - interval '5 months', date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month', 'pri_test_starter_monthly');

insert into public.subscriptions (user_id, plan, status, trial_ends_at, current_period_start)
values ('10000000-0000-4000-8000-000000000213', 'trial', 'trialing',
        now() - interval '20 days', now() - interval '40 days')
on conflict (user_id) do update set
    plan = excluded.plan, status = excluded.status,
    trial_ends_at = excluded.trial_ends_at,
    current_period_start = excluded.current_period_start;

-- Two calendar months for one user. A rolling "last 60 days" window would blend
-- these into one number; the contract is that it does not.
insert into public.usage_events (user_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) - interval '10 days', 'transcribe', 'deepgram:nova-3', 200, 3600, 1.00, 'stt'),
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '2 days', 'transcribe', 'deepgram:nova-3', 200, 7200, 2.00, 'stt');

-- Priced and unpriced calls: the unpriced one is counted and moves no money.
insert into public.usage_events (user_id, created_at, kind, model, status, prompt_tokens, completion_tokens, cost_usd, task)
values
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '3 days', 'chat', 'anthropic/claude', 200, 1000, 500, 0.50, 'summary'),
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '3 days', 'embed', 'openai/embed', 200, 100, 0, null, null);

insert into public.usage_events (user_id, created_at, kind, model, status, cost_usd, task)
values
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '4 days', 'integration', 'linear', 200, 0.01, 'ask'),
    ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '4 days', 'integration', 'gmail', 200, 0.01, 'ask');

-- The founder's own traffic: flagged internal, never dropped.
insert into public.usage_events (user_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values ('10000000-0000-4000-8000-000000000201', date_trunc('month', now()) + interval '1 day', 'transcribe', 'deepgram:nova-3', 200, 600, 0.10, 'stt');

insert into public.usage_events (user_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values ('10000000-0000-4000-8000-000000000213', date_trunc('month', now()) + interval '1 day', 'transcribe', 'deepgram:nova-3', 200, 3600, 0.30, 'stt');

insert into public.meetings (user_id, created_at, started_at, ended_at, summary)
values ('10000000-0000-4000-8000-000000000211', date_trunc('month', now()) + interval '2 days',
        date_trunc('month', now()) + interval '2 days', date_trunc('month', now()) + interval '2 days' + interval '1 hour', 'seed');

create temp table detail_snapshot (k text primary key, payload jsonb);
grant all on detail_snapshot to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000201","email":"vlad@hellonod.app","role":"authenticated"}';

do $$
declare
    v_this date := (date_trunc('month', (now() at time zone 'UTC')))::date;
    v_prev date := (v_this - interval '1 month')::date;
    v_floor numeric := (
        select min(display_amount) from public.plan_prices
         where plan = 'starter' and kind = 'subscription' and active
    );
    v_row record;
    v_detail jsonb;
begin
    -- Calendar months stay separate, and each carries only its own spend.
    if (select cost_usd from public.founder_user_monthly(6)
         where email = 'paid@example.invalid' and month = v_prev) <> 1.00
       or (select cost_usd from public.founder_user_monthly(6)
            where email = 'paid@example.invalid' and month = v_this) <> 2.52 then
        raise exception 'monthly spend did not split on the calendar month';
    end if;

    select * into v_row from public.founder_user_monthly(6)
     where email = 'paid@example.invalid' and month = v_this;

    -- The split columns are exhaustive: a stacked chart must reconcile.
    if v_row.stt_cost_usd + v_row.llm_cost_usd + v_row.other_cost_usd <> v_row.cost_usd then
        raise exception 'cost split does not add up to the total';
    end if;
    if v_row.stt_cost_usd <> 2.00 or v_row.llm_cost_usd <> 0.50 or v_row.other_cost_usd <> 0.02 then
        raise exception 'cost did not split by kind';
    end if;

    if v_row.unpriced_requests <> 1 then
        raise exception 'unpriced requests were not counted apart';
    end if;
    if v_row.integration_requests <> 2 then
        raise exception 'integration actions were not counted';
    end if;
    if v_row.meetings <> 1 or v_row.usage_days <> 3 then
        raise exception 'consumption counters are wrong';
    end if;

    -- Revenue starts at conversion and is never back-dated over earlier months.
    if v_row.mrr_usd <> 15 then
        raise exception 'converted month did not carry its list price';
    end if;
    if (select mrr_usd from public.founder_user_monthly(6)
         where email = 'paid@example.invalid' and month = v_prev) <> 0 then
        raise exception 'revenue was back-dated before conversion';
    end if;

    -- A lapsed subscription stops billing after the term it paid for.
    if (select mrr_usd from public.founder_user_monthly(6)
         where email = 'expired@example.invalid' and month = v_this) <> 0 then
        raise exception 'an expired subscription still billed';
    end if;

    -- Cancelled with no term end: an unknown ending stops revenue, not extends it.
    if (select mrr_usd from public.founder_user_monthly(6)
         where email = 'cancelled-no-term@example.invalid' and month = v_this) <> 0 then
        raise exception 'a cancelled subscription with no term billed forever';
    end if;

    -- Any fallback to a list price is flagged, including "no price id at all".
    if (select mrr_usd from public.founder_user_monthly(6)
         where email = 'retired-price@example.invalid' and month = v_this) <> v_floor
       or not (select mrr_estimated from public.founder_user_monthly(6)
                where email = 'retired-price@example.invalid' and month = v_this)
       or not (select mrr_estimated from public.founder_user_monthly(6)
                where email = 'no-price-id@example.invalid' and month = v_this)
       or (select mrr_estimated from public.founder_user_monthly(6)
            where email = 'paid@example.invalid' and month = v_this) then
        raise exception 'a guessed price was not reported as an estimate';
    end if;

    -- A trial bills nothing, so there is nothing to be an estimate of. Without
    -- this the flag fires on the majority of rows and stops meaning anything.
    if exists (
        select 1 from public.founder_user_monthly(6)
         where mrr_usd = 0 and mrr_estimated
    ) then
        raise exception 'a month that billed nothing was flagged as an estimate';
    end if;

    -- `converted_at` is the FIRST conversion and never moves, so a month before
    -- the term on the row is priced at today's plan. Shown, but never as fact.
    if not (select mrr_estimated from public.founder_user_monthly(6)
             where email = 'reactivated@example.invalid' and month = v_prev)
       or (select mrr_estimated from public.founder_user_monthly(6)
            where email = 'reactivated@example.invalid' and month = v_this) then
        raise exception 'a back-dated month was presented as fact';
    end if;

    -- A floor across every cycle, not just the dearer one: the reported number
    -- must be at or below the cheapest MONTHLY price, which is what filtering
    -- the fallback to monthly would have produced.
    if (select mrr_usd from public.founder_user_monthly(6)
         where email = 'retired-price@example.invalid' and month = v_this)
       > (select min(display_amount) from public.plan_prices
           where plan = 'starter' and kind = 'subscription'
             and billing_cycle = 'monthly' and active) then
        raise exception 'the price fallback was not a floor across billing cycles';
    end if;

    -- Paying and silent is the loudest churn signal on the page; it must appear.
    if not exists (
        select 1 from public.founder_user_monthly(6)
         where email = 'paid-and-silent@example.invalid' and month = v_this and mrr_usd > 0
    ) then
        raise exception 'a paying user with no traffic was dropped';
    end if;

    -- Internal traffic is flagged, not hidden, and customers are not flagged.
    if not (select is_internal from public.founder_user_monthly(6)
             where email = 'vlad@hellonod.app' and month = v_this)
       or (select is_internal from public.founder_user_monthly(6)
            where email = 'paid@example.invalid' and month = v_this) then
        raise exception 'internal flagging is wrong';
    end if;

    -- Every month in range is present even when nothing happened, so a trend
    -- line has a baseline rather than a gap.
    if (select count(*) from public.founder_user_monthly(6)
         where email = 'paid@example.invalid') <> 6 then
        raise exception 'quiet months were dropped from the series';
    end if;

    v_detail := public.founder_user_detail('10000000-0000-4000-8000-000000000211'::uuid, 6);

    insert into detail_snapshot values ('personal', v_detail);
    if (v_detail -> 'allowance' ->> 'hours_limit')::numeric <> 8 then
        raise exception 'the plan allowance did not reach the panel';
    end if;

    if (v_detail ->> 'window_start') is null or (v_detail ->> 'surfaces_window') <> 'all_time' then
        raise exception 'the payload did not name the windows it mixes';
    end if;

    if not exists (
        select 1 from jsonb_array_elements(v_detail -> 'by_task') t
         where t ->> 'task' = 'ask' and (t ->> 'requests')::int = 2
    ) then
        raise exception 'task breakdown lost the integration task';
    end if;

    if (v_detail -> 'surfaces' ->> 'meetings')::int <> 1 then
        raise exception 'surface counts did not reach the detail payload';
    end if;

    -- A run-out trial is placed on the live window, the way the entitlement
    -- resolver places it — not on the trial term that already closed.
    v_detail := public.founder_user_detail('10000000-0000-4000-8000-000000000213'::uuid, 6);
    if (v_detail ->> 'effective_status') <> 'expired'
       or (v_detail -> 'allowance' ->> 'period_end')::timestamptz < now() then
        raise exception 'an over-run trial reported a window that had already closed';
    end if;

    if (public.founder_user_detail(gen_random_uuid(), 6) ->> 'not_found') <> 'true' then
        raise exception 'an unknown user did not report itself as missing';
    end if;
end;
$$;
reset role;

-- A member of a paying workspace is metered out of the workspace pool, on the
-- workspace's period, against the workspace's ceiling. The panel must report
-- that pool — not the personal trial the member's own row still carries.
insert into public.organizations (id, name, slug, created_by)
values ('50000000-0000-4000-8000-000000000001', 'Test workspace', 'test-workspace-contract',
        '10000000-0000-4000-8000-000000000218');
insert into public.org_members (org_id, user_id, role, status, joined_at)
values ('50000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000218',
        'owner', 'active', now() - interval '30 days');
insert into public.org_subscriptions (
    org_id, plan, status, seats, current_period_start, current_period_end, purchased_by
)
values ('50000000-0000-4000-8000-000000000001', 'teams', 'active', 3,
        date_trunc('month', now()), date_trunc('month', now()) + interval '1 month',
        '10000000-0000-4000-8000-000000000218');
update public.profiles set active_org_id = '50000000-0000-4000-8000-000000000001'
 where user_id = '10000000-0000-4000-8000-000000000218';

-- Inside the workspace period, so the window cannot be what hides it.
insert into public.usage_events (user_id, org_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values ('10000000-0000-4000-8000-000000000218', '50000000-0000-4000-8000-000000000001',
        now() - interval '1 hour', 'transcribe', 'deepgram:nova-3', 200, 7200, 0.50, 'stt');
insert into public.usage_events (user_id, org_id, created_at, kind, model, status, cost_usd, task)
values ('10000000-0000-4000-8000-000000000218', '50000000-0000-4000-8000-000000000001',
        now() - interval '1 hour', 'integration', 'linear', 200, 0.01, 'ask');

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000201","email":"vlad@hellonod.app","role":"authenticated"}';
do $$
declare
    v_detail jsonb := public.founder_user_detail('10000000-0000-4000-8000-000000000218'::uuid, 6);
begin
    insert into detail_snapshot values ('workspace', v_detail);
    if (v_detail -> 'allowance' ->> 'payer') <> 'organization'
       or (v_detail -> 'allowance' ->> 'org_id') <> '50000000-0000-4000-8000-000000000001'
       or (v_detail -> 'allowance' ->> 'seats')::int <> 3 then
        raise exception 'a workspace seat was reported as a personal plan';
    end if;
    -- The workspace pool is bigger than any personal plan, which is the whole
    -- point: reporting the trial's ceiling here would understate it many times.
    if (v_detail -> 'allowance' ->> 'hours_limit')::numeric <= 8 then
        raise exception 'the workspace pool was not reported';
    end if;
    -- We paid for it either way, so it still belongs in the cost report.
    if (select cost_usd from public.founder_user_monthly(6)
         where email = 'workspace-user@example.invalid'
           and month = (date_trunc('month', (now() at time zone 'UTC')))::date) <> 0.51 then
        raise exception 'workspace usage vanished from the cost report';
    end if;
end;
$$;
reset role;

-- The allowance is not re-derived from the schema, so the contract is field-by-
-- field agreement with the function the product itself gates on. Run as the
-- owner: `resolve_entitlement` is not granted to `authenticated`, which is why
-- `founder_user_detail` reaches it as a definer in the first place.
do $$
declare
    r record;
    v_ent jsonb;
begin
    for r in select k, payload from detail_snapshot loop
        v_ent := public.resolve_entitlement((r.payload ->> 'user_id')::uuid);
        if (r.payload -> 'allowance' ->> 'payer') is distinct from (v_ent ->> 'payer')
           or (r.payload -> 'allowance' ->> 'hours_used')::numeric
              is distinct from round((v_ent ->> 'consumed_seconds')::numeric / 3600.0, 2)
           or (r.payload -> 'allowance' ->> 'hours_limit')::numeric
              is distinct from round((v_ent ->> 'included_seconds')::numeric / 3600.0, 2)
           or (r.payload -> 'allowance' ->> 'credits_used')::numeric
              is distinct from (v_ent ->> 'integration_credits_used')::numeric
           or (r.payload -> 'allowance' ->> 'credits_limit')::numeric
              is distinct from (v_ent ->> 'integration_credits_included')::numeric
           or (r.payload -> 'allowance' ->> 'period_start')::timestamptz
              is distinct from (v_ent ->> 'usage_period_start')::timestamptz
           or (r.payload ->> 'effective_status') is distinct from (v_ent ->> 'status') then
            raise exception 'the % allowance panel disagrees with the entitlement resolver', r.k;
        end if;
    end loop;
    if (select count(*) from detail_snapshot) < 2 then
        raise exception 'the resolver parity check ran on nothing';
    end if;
end;
$$;

-- Months are bucketed in UTC because these totals are reconciled against
-- provider invoices. A session in a far-eastern timezone must not move an
-- event across the month boundary.
set local timezone = 'Pacific/Kiritimati';
insert into public.usage_events (user_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values ('10000000-0000-4000-8000-000000000212', timestamptz '2026-08-31 23:00+00',
        'transcribe', 'deepgram:nova-3', 200, 60, 0.07, 'stt');
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000201","email":"vlad@hellonod.app","role":"authenticated"}';
do $$
begin
    if not exists (
        select 1 from public.founder_user_monthly(24)
         where email = 'retired-price@example.invalid'
           and month = date '2026-08-01' and cost_usd >= 0.07
    ) then
        raise exception 'a month boundary moved with the session timezone';
    end if;
end;
$$;
reset role;
set local timezone = 'UTC';

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000211","email":"paid@example.invalid","role":"authenticated"}';
do $$
begin
    begin
        perform public.founder_user_monthly(6);
        raise exception 'non-founder read the monthly costs';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.founder_user_detail('10000000-0000-4000-8000-000000000211'::uuid, 6);
        raise exception 'non-founder read a user in full';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;

set local role anon;
set local request.jwt.claims = '{}';
do $$
begin
    begin
        perform public.founder_user_monthly(6);
        raise exception 'anon read the monthly costs';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.founder_user_detail('10000000-0000-4000-8000-000000000211'::uuid, 6);
        raise exception 'anon read a user in full';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;

rollback;
