-- Corrections to the per-user monthly cost report, from an independent review.
--
-- `20260909180000` shipped the report. Nothing in production consumes it yet —
-- the dashboard that calls it has not been deployed — so both functions are
-- replaced outright rather than versioned. Deploy order is this migration
-- first, the dashboard second; rolling back is dropping these two functions,
-- which no released client calls.
--
-- What was wrong, in the order it costs a decision:
--
--   1. A subscriber who paid and then stopped using the product produced no
--      row at all, because the report was built from traffic. That is the
--      highest-margin row on the page and the loudest churn signal, and it was
--      the one row missing. Anyone who converted is now an actor in their own
--      right.
--   2. Only `canceled` stopped revenue, and only when `current_period_end` was
--      set — which Paddle does not always send. An `expired` subscription, or a
--      cancelled one with a null term, billed at list price every month
--      forever.
--   3. `mrr_estimated` stayed false when the price lookup missed because the
--      subscription carried no price id at all, which is exactly when the
--      number is a guess. The flag now fires on any fallback.
--   4. The fallback itself filtered to monthly prices, and monthly is the dearer
--      cycle — so a retired yearly price was replaced by a number up to 55%
--      above what that subscriber actually pays, under a comment promising a
--      floor. It is now a floor across every cycle.
--   5. `founder_user_detail` reported an allowance window that had already
--      closed for an over-run trial, and counted usage the entitlement meter
--      does not count, under a comment claiming the two agreed.
--
-- `search_path` is empty and every relation is qualified, matching
-- `resolve_entitlement`. With `public` on the path an implicit `pg_temp` sits
-- in front of it, and a temp table named after a product table would quietly
-- change what a SECURITY DEFINER function reads.
--
-- Organization billing is still out of scope here: `org_subscriptions` is a
-- separate payer with its own seats and period, and every number below is the
-- personal slice. That is stated in the column comments rather than implied.

drop function if exists public.founder_user_monthly(int);

create function public.founder_user_monthly(p_months int default 6)
returns table (
  user_id uuid,
  email text,
  display_name text,
  is_internal boolean,
  month date,
  cost_usd numeric,
  stt_cost_usd numeric,
  llm_cost_usd numeric,
  -- Everything that is neither transcription nor LLM generation: embeddings,
  -- speech, integration actions. Present so the three split columns add up to
  -- `cost_usd` exactly, and a stacked chart built from them reconciles.
  other_cost_usd numeric,
  requests bigint,
  errors bigint,
  -- Calls the proxy recorded no cost for — embeddings today. Counted apart so a
  -- $0.00 line reads as "not metered" rather than "served for free".
  unpriced_requests bigint,
  prompt_tokens bigint,
  completion_tokens bigint,
  audio_minutes numeric,
  integration_requests bigint,
  meetings bigint,
  -- Days the proxy saw ANY call from this user, including embeddings and
  -- integration polling the client makes on its own. Deliberately not the
  -- product's "active" (>=1 meeting), which `meetings` above answers.
  usage_days bigint,
  -- Monthly-equivalent list price of the personal plan, counted only for months
  -- at or after the user converted and no later than the term they paid for.
  -- Plan history is not stored, so an earlier month reports $0 rather than
  -- back-dating the plan someone is on today. Workspace revenue is not here.
  mrr_usd numeric,
  -- True whenever the subscription's price id did not resolve in `plan_prices`
  -- — retired, or never set — so `mrr_usd` is the plan's cheapest live rate
  -- across every billing cycle: a floor, not the invoice.
  mrr_estimated boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_months int := least(greatest(coalesce(p_months, 6), 1), 24);
  -- Months are bucketed in UTC, not the session timezone: these totals are
  -- reconciled against provider invoices, and those bill in UTC.
  v_this_month date := (date_trunc('month', (now() at time zone 'UTC')))::date;
  v_first_month date := (v_this_month - make_interval(months => v_months - 1))::date;
  v_since timestamptz := v_first_month::timestamp at time zone 'UTC';
begin
  perform public._assert_founder();
  return query
  with usage as (
    select
      ue.user_id                                                         as uid,
      (date_trunc('month', ue.created_at at time zone 'UTC'))::date      as m,
      coalesce(sum(ue.cost_usd), 0)                                      as cost,
      coalesce(sum(ue.cost_usd) filter (where ue.kind = 'transcribe'), 0) as stt,
      coalesce(sum(ue.cost_usd) filter (where ue.kind = 'chat'), 0)      as llm,
      coalesce(sum(ue.cost_usd) filter (
        where ue.kind not in ('transcribe', 'chat')), 0)                 as other,
      count(*)                                                           as reqs,
      count(*) filter (where ue.status < 200 or ue.status >= 300)        as errs,
      count(*) filter (where ue.cost_usd is null)                        as unpriced,
      coalesce(sum(ue.prompt_tokens), 0)::bigint                         as ptok,
      coalesce(sum(ue.completion_tokens), 0)::bigint                     as ctok,
      coalesce(sum(ue.audio_seconds) / 60.0, 0)                          as audio_min,
      count(*) filter (where ue.kind = 'integration')                    as integrations,
      count(distinct (ue.created_at at time zone 'UTC')::date)           as days
    from public.usage_events ue
    where ue.created_at >= v_since
    group by 1, 2
  ),
  mtg as (
    select
      mt.user_id                                                    as uid,
      (date_trunc('month', mt.created_at at time zone 'UTC'))::date as m,
      count(*)                                                      as n
    from public.meetings mt
    where mt.created_at >= v_since
    group by 1, 2
  ),
  price as (
    select
      s.user_id as uid,
      s.status,
      s.converted_at,
      -- The last month a lapsed subscription still bills for. A term Paddle
      -- never sent falls back to the conversion month, so an unknown ending
      -- stops revenue instead of extending it indefinitely.
      (date_trunc('month', coalesce(s.current_period_end, s.converted_at)))::date as term_end_month,
      coalesce(pp.display_amount, listed.floor_amount, 0) as monthly_usd,
      pp.paddle_price_id is null as estimated
    from public.subscriptions s
    left join public.plan_prices pp on pp.paddle_price_id = s.paddle_price_id
    left join lateral (
      select min(p2.display_amount) as floor_amount
      from public.plan_prices p2
      where p2.plan = s.plan
        and p2.kind = 'subscription'
        and p2.active
    ) listed on true
  ),
  actors as (
    select uid from usage
    union
    select uid from mtg
    union
    -- Someone who converted belongs on this report whether or not they showed
    -- up this month. Paying and silent is a finding, not an absence.
    select s.user_id from public.subscriptions s where s.converted_at is not null
  ),
  span as (
    select generate_series(v_first_month, v_this_month, interval '1 month')::date as m
  )
  select
    a.uid,
    u.email::text,
    pr.display_name,
    lower(u.email) = any(public._founder_emails()),
    s.m,
    coalesce(round(us.cost, 6), 0),
    coalesce(round(us.stt, 6), 0),
    coalesce(round(us.llm, 6), 0),
    coalesce(round(us.other, 6), 0),
    coalesce(us.reqs, 0)::bigint,
    coalesce(us.errs, 0)::bigint,
    coalesce(us.unpriced, 0)::bigint,
    coalesce(us.ptok, 0)::bigint,
    coalesce(us.ctok, 0)::bigint,
    coalesce(round(us.audio_min, 2), 0),
    coalesce(us.integrations, 0)::bigint,
    coalesce(mt.n, 0)::bigint,
    coalesce(us.days, 0)::bigint,
    case
      when pc.converted_at is null then 0
      when s.m < (date_trunc('month', pc.converted_at))::date then 0
      -- A live subscription bills this month. `past_due` still holds the
      -- entitlement while Paddle retries, so it still counts as revenue owed.
      when pc.status in ('active', 'past_due') then coalesce(pc.monthly_usd, 0)
      -- Anything else — cancelled, expired, paused — bills only through the
      -- term already paid for.
      when pc.term_end_month is not null and s.m <= pc.term_end_month
        then coalesce(pc.monthly_usd, 0)
      else 0
    end,
    coalesce(pc.estimated, false)
  from actors a
  cross join span s
  join auth.users u on u.id = a.uid
  left join public.profiles pr on pr.user_id = a.uid
  left join usage us on us.uid = a.uid and us.m = s.m
  left join mtg mt on mt.uid = a.uid and mt.m = s.m
  left join price pc on pc.uid = a.uid
  order by u.email, s.m;
end;
$$;

revoke all on function public.founder_user_monthly(int) from public, anon;
grant execute on function public.founder_user_monthly(int) to authenticated;

comment on function public.founder_user_monthly(int) is
  'Per user, per UTC calendar month: what we spent serving them, what they consumed, and the personal list-price revenue that month carried. Workspace billing is not included. Founder-gated.';


drop function if exists public.founder_user_detail(uuid, int);

create function public.founder_user_detail(p_user_id uuid, p_months int default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_months int := least(greatest(coalesce(p_months, 6), 1), 24);
  v_since timestamptz := (date_trunc('month', (now() at time zone 'UTC'))
                          - make_interval(months => v_months - 1))::timestamp at time zone 'UTC';
  v_sub public.subscriptions%rowtype;
  v_plan public.plans%rowtype;
  v_status text;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_hours_limit numeric;
  v_credits_limit numeric;
  v_hours_unlimited boolean;
  v_topups_count boolean;
  v_result jsonb;
begin
  perform public._assert_founder();

  select * into v_sub from public.subscriptions where user_id = p_user_id;
  select * into v_plan from public.plans where plan = coalesce(v_sub.plan, 'trial');

  -- `resolve_entitlement` normalises a run-out trial to `expired` BEFORE it
  -- places the usage window. Passing the raw status instead would place the
  -- window on the trial term that already ended, and report "0 of 5 hours used"
  -- for somebody who is out of trial and burning hours right now.
  v_status := v_sub.status;
  if v_status = 'trialing' and v_sub.trial_ends_at is not null and v_sub.trial_ends_at < now() then
    v_status := 'expired';
  end if;

  if v_sub.user_id is not null then
    select w.period_start, w.period_end
      into v_period_start, v_period_end
      from public.monthly_usage_window(
             v_status, v_sub.trial_ends_at,
             v_sub.current_period_start, v_sub.current_period_end
           ) w;
  end if;

  -- No subscription row, or a window the resolver could not place: fall back to
  -- the calendar month so the allowance panel still has an honest denominator.
  v_period_start := coalesce(v_period_start, date_trunc('month', now()));
  v_period_end := coalesce(v_period_end, date_trunc('month', now()) + interval '1 month');

  -- A per-subscription override beats the plan default, which is the order
  -- `resolve_entitlement` applies; grandfathered ceilings live in the override.
  v_hours_limit := coalesce(
    (v_sub.limit_overrides ->> 'hours_per_month')::numeric,
    (v_plan.limits ->> 'hours_per_month')::numeric
  );
  v_credits_limit := coalesce(
    (v_sub.limit_overrides ->> 'integration_credits_per_month')::numeric,
    (v_plan.limits ->> 'integration_credits_per_month')::numeric
  );
  v_hours_unlimited := coalesce(v_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false);
  -- The resolver only honours a top-up while the subscription is live.
  v_topups_count := coalesce(v_status in ('active', 'past_due', 'trialing'), false);

  select jsonb_build_object(
    'user_id', p_user_id,
    'email', u.email::text,
    'display_name', pr.display_name,
    'created_at', u.created_at,
    'app_version', pr.app_version,
    'os_version', pr.os_version,
    'plan', coalesce(v_sub.plan, 'trial'),
    'plan_name', v_plan.display_name,
    'sub_status', v_sub.status,
    -- What the entitlement resolver would treat this subscription as today.
    'effective_status', v_status,
    'trial_ends_at', v_sub.trial_ends_at,
    'converted_at', v_sub.converted_at,
    -- Three different windows are reported below, so each one names its own.
    'window_start', v_since,
    'surfaces_window', 'all_time',
    'allowance', jsonb_build_object(
      'period_start', v_period_start,
      'period_end', v_period_end,
      'hours_limit', v_hours_limit,
      'hours_unlimited', v_hours_unlimited,
      'hours_used', (
        -- `org_id is null` mirrors the resolver's personal branch: usage stamped
        -- to a workspace is charged to that workspace's pool, not to this user.
        select coalesce(round(sum(ue.audio_seconds) / 3600.0, 2), 0)
        from public.usage_events ue
        where ue.user_id = p_user_id
          and ue.kind = 'transcribe'
          and ue.org_id is null
          and ue.created_at >= v_period_start
          and ue.created_at < v_period_end
      ),
      'hours_topped_up', case when v_topups_count then (
        select coalesce(sum(t.hours), 0)
        from public.usage_topups t
        where t.user_id = p_user_id
          and t.status = 'active'
          and t.org_id is null
          and t.period_start = v_period_start
          and t.period_end = v_period_end
      ) else 0 end,
      'credits_limit', v_credits_limit,
      'credits_used', (
        -- One metered integration action is one `usage_events` row of kind
        -- `integration`, which is the same meter the resolver counts.
        select count(*)
        from public.usage_events ue
        where ue.user_id = p_user_id
          and ue.kind = 'integration'
          and ue.org_id is null
          and ue.created_at >= v_period_start
          and ue.created_at < v_period_end
      ),
      'credits_topped_up', case when v_topups_count then (
        select coalesce(sum(t.credits), 0)
        from public.usage_topups t
        where t.user_id = p_user_id
          and t.status = 'active'
          and t.org_id is null
          and t.period_start = v_period_start
          and t.period_end = v_period_end
      ) else 0 end
    ),
    'by_task', coalesce((
      select jsonb_agg(x order by x.cost_usd desc)
      from (
        select
          ue.kind,
          ue.task,
          count(*) as requests,
          coalesce(round(sum(ue.cost_usd), 6), 0) as cost_usd,
          count(*) filter (where ue.cost_usd is null) as unpriced_requests,
          coalesce(round(sum(ue.audio_seconds) / 60.0, 1), 0) as audio_minutes,
          coalesce(sum(ue.prompt_tokens) + sum(ue.completion_tokens), 0)::bigint as tokens
        from public.usage_events ue
        where ue.user_id = p_user_id and ue.created_at >= v_since
        group by ue.kind, ue.task
      ) x
    ), '[]'::jsonb),
    'by_model', coalesce((
      select jsonb_agg(x order by x.cost_usd desc)
      from (
        select
          coalesce(ue.model, 'unknown') as model,
          ue.kind,
          count(*) as requests,
          count(*) filter (where ue.failover is not null) as failovers,
          coalesce(round(sum(ue.cost_usd), 6), 0) as cost_usd
        from public.usage_events ue
        where ue.user_id = p_user_id and ue.created_at >= v_since
        group by coalesce(ue.model, 'unknown'), ue.kind
      ) x
    ), '[]'::jsonb),
    'surfaces', jsonb_build_object(
      'meetings', (select count(*) from public.meetings m where m.user_id = p_user_id),
      'chat_messages', (select count(*) from public.chat_messages c where c.user_id = p_user_id),
      'action_items', (select count(*) from public.action_items ai where ai.user_id = p_user_id),
      'shared_meetings', (
        select count(*) from public.meeting_shares ms
        where ms.created_by = p_user_id and ms.revoked_at is null
      ),
      'knowledge_threads', (select count(*) from public.knowledge_threads k where k.user_id = p_user_id),
      'knowledge_messages', (
        select count(*) from public.knowledge_messages km where km.user_id = p_user_id
      ),
      'screen_observations', (
        select count(*) from public.screen_observations so where so.user_id = p_user_id
      ),
      'live_connections', (
        select count(*) from public.connections c
        where c.user_id = p_user_id and c.revoked_at is null
      ),
      'devices', (select count(*) from public.user_devices d where d.user_id = p_user_id)
    ),
    'generated_at', now()
  )
  into v_result
  from auth.users u
  left join public.profiles pr on pr.user_id = u.id
  where u.id = p_user_id;

  return coalesce(v_result, jsonb_build_object('user_id', p_user_id, 'not_found', true));
end;
$$;

revoke all on function public.founder_user_detail(uuid, int) from public, anon;
grant execute on function public.founder_user_detail(uuid, int) to authenticated;

comment on function public.founder_user_detail(uuid, int) is
  'One user in full: plan, personal allowance burn over the live billing period, spend by task and model, and which product surfaces they touch. Workspace-attributed usage is excluded. Founder-gated.';
