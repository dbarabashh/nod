-- What one user costs us in a month, and what they consumed to cost it.
--
-- The founder dashboard could already answer "what did we spend over the last N
-- days" and projected a monthly rate from that window. A projection cannot be
-- compared month to month, and it is the month-to-month line that a price, a
-- rate limit and a churn call are actually argued from. These two functions
-- answer it directly.
--
-- Calendar months, not billing periods, on purpose. Each subscriber's period
-- starts on their own anniversary, so period totals are comparable neither
-- between users nor against the provider invoices we reconcile against. Burn
-- against the plan allowance IS a billing-period question, so it is answered
-- separately, in `founder_user_detail`, over the window the entitlement
-- resolver actually uses.
--
-- Like `founder_user_costs` and unlike the product metrics, these do NOT exclude
-- the founder accounts: "what does our own usage cost" is half the question the
-- Costs page exists for. Internal rows are flagged, not hidden.

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
  active_days bigint,
  -- Monthly-equivalent list price of the plan, counted only for months at or
  -- after the user converted and before a cancelled term ran out. Plan history
  -- is not stored, so an earlier month reports $0 rather than back-dating the
  -- plan someone is on today.
  mrr_usd numeric,
  -- True when the subscription's Paddle price id is not in `plan_prices` (a
  -- retired price), so `mrr_usd` fell back to the plan's cheapest live monthly
  -- rate and is a floor, not the invoice.
  mrr_estimated boolean
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_months int := least(greatest(coalesce(p_months, 6), 1), 24);
  v_since timestamptz := date_trunc('month', now()) - make_interval(months => v_months - 1);
begin
  perform public._assert_founder();
  return query
  with usage as (
    select
      ue.user_id                                                    as uid,
      date_trunc('month', ue.created_at)::date                      as m,
      coalesce(sum(ue.cost_usd), 0)                                 as cost,
      coalesce(sum(ue.cost_usd) filter (where ue.kind = 'transcribe'), 0) as stt,
      coalesce(sum(ue.cost_usd) filter (where ue.kind = 'chat'), 0)      as llm,
      count(*)                                                      as reqs,
      count(*) filter (where ue.status < 200 or ue.status >= 300)   as errs,
      count(*) filter (where ue.cost_usd is null)                   as unpriced,
      coalesce(sum(ue.prompt_tokens), 0)::bigint                    as ptok,
      coalesce(sum(ue.completion_tokens), 0)::bigint                as ctok,
      coalesce(sum(ue.audio_seconds) / 60.0, 0)                     as audio_min,
      count(*) filter (where ue.kind = 'integration')               as integrations,
      count(distinct ue.created_at::date)                           as days
    from usage_events ue
    where ue.created_at >= v_since
    group by 1, 2
  ),
  mtg as (
    select mt.user_id as uid, date_trunc('month', mt.created_at)::date as m, count(*) as n
    from meetings mt
    where mt.created_at >= v_since
    group by 1, 2
  ),
  price as (
    select
      s.user_id as uid,
      s.status,
      s.converted_at,
      s.current_period_end,
      coalesce(pp.display_amount, listed.floor_amount, 0) as monthly_usd,
      pp.paddle_price_id is null and s.paddle_price_id is not null as estimated
    from subscriptions s
    left join plan_prices pp on pp.paddle_price_id = s.paddle_price_id
    left join lateral (
      select min(p2.display_amount) as floor_amount
      from plan_prices p2
      where p2.plan = s.plan
        and p2.kind = 'subscription'
        and p2.billing_cycle = 'monthly'
        and p2.active
    ) listed on true
  ),
  actors as (
    select uid from usage
    union
    select uid from mtg
  ),
  span as (
    select generate_series(
             date_trunc('month', v_since),
             date_trunc('month', now()),
             interval '1 month'
           )::date as m
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
      when s.m < date_trunc('month', pc.converted_at)::date then 0
      when pc.status = 'canceled'
           and pc.current_period_end is not null
           and s.m > date_trunc('month', pc.current_period_end)::date then 0
      else coalesce(pc.monthly_usd, 0)
    end,
    coalesce(pc.estimated, false)
  from actors a
  cross join span s
  join auth.users u on u.id = a.uid
  left join profiles pr on pr.user_id = a.uid
  left join usage us on us.uid = a.uid and us.m = s.m
  left join mtg mt on mt.uid = a.uid and mt.m = s.m
  left join price pc on pc.uid = a.uid
  order by u.email, s.m;
end;
$$;

revoke all on function public.founder_user_monthly(int) from public, anon;
grant execute on function public.founder_user_monthly(int) to authenticated;

comment on function public.founder_user_monthly(int) is
  'Per user, per calendar month: what we spent serving them, what they consumed, and the list-price revenue that month carried. Founder-gated.';


-- Everything about one user that a row in the dashboard cannot hold: the plan
-- and what it entitles them to, how far into that entitlement they are this
-- billing period, what their spend went on, and which of the newer surfaces
-- they actually touch.
--
-- Read lazily, one call per expanded row, so the users table stays one query.

drop function if exists public.founder_user_detail(uuid, int);

create function public.founder_user_detail(p_user_id uuid, p_months int default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_months int := least(greatest(coalesce(p_months, 6), 1), 24);
  v_since timestamptz := date_trunc('month', now()) - make_interval(months => v_months - 1);
  v_sub subscriptions%rowtype;
  v_plan plans%rowtype;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_hours_limit numeric;
  v_credits_limit numeric;
  v_hours_unlimited boolean;
  v_result jsonb;
begin
  perform public._assert_founder();

  select * into v_sub from subscriptions where user_id = p_user_id;
  select * into v_plan from plans where plan = coalesce(v_sub.plan, 'trial');

  if v_sub.user_id is not null then
    select w.period_start, w.period_end
      into v_period_start, v_period_end
      from public.monthly_usage_window(
             v_sub.status, v_sub.trial_ends_at,
             v_sub.current_period_start, v_sub.current_period_end
           ) w;
  end if;

  -- No subscription row, or a window the resolver could not place: fall back to
  -- the calendar month so the allowance panel still has an honest denominator.
  v_period_start := coalesce(v_period_start, date_trunc('month', now()));
  v_period_end := coalesce(v_period_end, date_trunc('month', now()) + interval '1 month');

  -- A per-subscription override beats the plan default; that is the order
  -- `resolve_entitlement` applies, and grandfathered ceilings live there.
  v_hours_limit := coalesce(
    (v_sub.limit_overrides ->> 'hours_per_month')::numeric,
    (v_plan.limits ->> 'hours_per_month')::numeric
  );
  v_credits_limit := coalesce(
    (v_sub.limit_overrides ->> 'integration_credits_per_month')::numeric,
    (v_plan.limits ->> 'integration_credits_per_month')::numeric
  );
  v_hours_unlimited := coalesce(v_sub.hours_are_unlimited, v_plan.hours_are_unlimited, false);

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
    'trial_ends_at', v_sub.trial_ends_at,
    'converted_at', v_sub.converted_at,
    'allowance', jsonb_build_object(
      'period_start', v_period_start,
      'period_end', v_period_end,
      'hours_limit', v_hours_limit,
      'hours_unlimited', v_hours_unlimited,
      'hours_used', (
        select coalesce(round(sum(ue.audio_seconds) / 3600.0, 2), 0)
        from usage_events ue
        where ue.user_id = p_user_id
          and ue.kind = 'transcribe'
          and ue.created_at >= v_period_start
          and ue.created_at < v_period_end
      ),
      'hours_topped_up', (
        select coalesce(sum(t.hours), 0)
        from usage_topups t
        where t.user_id = p_user_id
          and t.status = 'active'
          and t.period_start <= now()
          and t.period_end > now()
      ),
      'credits_limit', v_credits_limit,
      'credits_used', (
        -- One metered integration action is one usage_events row of kind
        -- `integration`; that is the meter `resolve_entitlement` counts too.
        select count(*)
        from usage_events ue
        where ue.user_id = p_user_id
          and ue.kind = 'integration'
          and ue.created_at >= v_period_start
          and ue.created_at < v_period_end
      ),
      'credits_topped_up', (
        select coalesce(sum(t.credits), 0)
        from usage_topups t
        where t.user_id = p_user_id
          and t.status = 'active'
          and t.period_start <= now()
          and t.period_end > now()
      )
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
        from usage_events ue
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
        from usage_events ue
        where ue.user_id = p_user_id and ue.created_at >= v_since
        group by coalesce(ue.model, 'unknown'), ue.kind
      ) x
    ), '[]'::jsonb),
    'surfaces', jsonb_build_object(
      'meetings', (select count(*) from meetings m where m.user_id = p_user_id),
      'chat_messages', (select count(*) from chat_messages c where c.user_id = p_user_id),
      'action_items', (select count(*) from action_items ai where ai.user_id = p_user_id),
      'shared_meetings', (
        select count(*) from meeting_shares ms
        where ms.created_by = p_user_id and ms.revoked_at is null
      ),
      'knowledge_threads', (select count(*) from knowledge_threads k where k.user_id = p_user_id),
      'knowledge_messages', (
        select count(*) from knowledge_messages km where km.user_id = p_user_id
      ),
      'screen_observations', (select count(*) from screen_observations so where so.user_id = p_user_id),
      'live_connections', (
        select count(*) from connections c
        where c.user_id = p_user_id and c.revoked_at is null
      ),
      'devices', (select count(*) from user_devices d where d.user_id = p_user_id)
    ),
    'generated_at', now()
  )
  into v_result
  from auth.users u
  left join profiles pr on pr.user_id = u.id
  where u.id = p_user_id;

  return coalesce(v_result, jsonb_build_object('user_id', p_user_id, 'not_found', true));
end;
$$;

revoke all on function public.founder_user_detail(uuid, int) from public, anon;
grant execute on function public.founder_user_detail(uuid, int) to authenticated;

comment on function public.founder_user_detail(uuid, int) is
  'One user in full: plan, allowance burn over the live billing period, spend by task and model, and which product surfaces they touch. Founder-gated.';
