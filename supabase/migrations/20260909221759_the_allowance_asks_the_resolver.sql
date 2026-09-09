-- The allowance panel stops re-deriving the entitlement and asks for it.
--
-- A second review found that `founder_user_detail` reimplemented the personal
-- branch of `resolve_entitlement` and only the personal branch. A member of a
-- paying workspace was reported against a trial's five hours while the product
-- was granting them seventy-five, and a `past_due` subscriber was shown top-ups
-- the resolver had already zeroed. Nine of nine allowance fields disagreed, on
-- a page whose whole claim is that its numbers are the ones the product uses.
--
-- Reimplementing it more carefully would only postpone the next divergence, so
-- this calls `public.resolve_entitlement` — the same function the clients gate
-- on — and reports what it returns: payer, period, limits and burn, workspace
-- or personal. The comments that claimed parity are now true by construction.
--
-- `founder_user_monthly` gets three revenue corrections from the same review:
--
--   1. `mrr_estimated` fired on every trial row, because a trial has no price
--      id. A month that bills nothing is not an estimate of anything, and the
--      flag was about to appear on the majority of rows and mean nothing.
--   2. `converted_at` is the FIRST conversion and is never moved, so somebody
--      who converted, churned and came back was billed at today's price for
--      every month in between — six months of revenue for one month of money.
--      A plan upgrade back-dated the same way. Months outside the term we can
--      actually evidence are still shown, because a trend with holes is worse,
--      but they are now flagged rather than presented as fact.
--   3. A cancelled row with no term end fell all the way back to `converted_at`
--      and reported $0 for somebody who was inside a paid period days earlier.
--      `current_period_start` is NOT NULL and is the better anchor.
--
-- Deploy order and rollback are unchanged: this migration first, the dashboard
-- second; rolling back means dropping both functions, which no released client
-- calls.

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
  -- Monthly-equivalent list price of the personal plan for that month. Zero
  -- before the user converted and after the term they last paid for. Workspace
  -- revenue is not here — `org_subscriptions` is a separate payer.
  mrr_usd numeric,
  -- True when `mrr_usd` is a reconstruction rather than a price we hold: the
  -- price id no longer resolves, or the month falls outside the billing term on
  -- the subscription row. Plan and price history are not stored, so a month
  -- before the current term is priced at today's plan and flagged here.
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
      (date_trunc('month', s.current_period_start))::date as term_start_month,
      -- The last month a lapsed subscription still bills for. Paddle does not
      -- always send a term end; `current_period_start` is NOT NULL and is a far
      -- better anchor than the first-ever conversion.
      (date_trunc('month', coalesce(
        s.current_period_end,
        s.current_period_start + interval '1 month',
        s.converted_at
      )))::date as term_end_month,
      coalesce(pp.display_amount, listed.floor_amount, 0) as monthly_usd,
      pp.paddle_price_id is null as price_unresolved
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
    -- Someone who paid belongs on this report whether or not they showed up.
    -- Paying and silent is a finding, not an absence. Bounded to subscriptions
    -- whose term reaches into the window, so a long-dead account does not add
    -- a run of empty rows forever.
    select s.user_id
    from public.subscriptions s
    where s.converted_at is not null
      and coalesce(s.current_period_end, s.current_period_start) >= v_since
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
    calc.mrr,
    -- A month that bills nothing is not an estimate of anything, so the flag is
    -- only ever true on a month that carries revenue.
    calc.mrr > 0 and (
      coalesce(pc.price_unresolved, false)
      or (pc.term_start_month is not null and s.m < pc.term_start_month)
    )
  from actors a
  cross join span s
  join auth.users u on u.id = a.uid
  left join public.profiles pr on pr.user_id = a.uid
  left join usage us on us.uid = a.uid and us.m = s.m
  left join mtg mt on mt.uid = a.uid and mt.m = s.m
  left join price pc on pc.uid = a.uid
  cross join lateral (
    select case
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
    end as mrr
  ) calc
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
  -- The entitlement exactly as the product resolves it: the right payer, the
  -- right window, the right ceiling. Asking rather than re-deriving is the
  -- whole point — a workspace seat and a personal plan are different branches,
  -- and only one of them was ever implemented here.
  v_ent jsonb := public.resolve_entitlement(p_user_id);
  v_sub public.subscriptions%rowtype;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_result jsonb;
begin
  perform public._assert_founder();

  select * into v_sub from public.subscriptions where user_id = p_user_id;

  -- A user the resolver cannot place has no period to report burn against;
  -- the calendar month keeps the panel's denominator honest rather than blank.
  v_period_start := coalesce((v_ent ->> 'usage_period_start')::timestamptz,
                             date_trunc('month', now()));
  v_period_end := coalesce((v_ent ->> 'usage_period_end')::timestamptz,
                           date_trunc('month', now()) + interval '1 month');

  select jsonb_build_object(
    'user_id', p_user_id,
    'email', u.email::text,
    'display_name', pr.display_name,
    'created_at', u.created_at,
    'app_version', pr.app_version,
    'os_version', pr.os_version,
    'plan', v_ent ->> 'plan',
    'sub_status', v_sub.status,
    -- What the entitlement resolver treats this subscription as today, which is
    -- what the product actually enforces.
    'effective_status', v_ent ->> 'status',
    'trial_ends_at', v_sub.trial_ends_at,
    'converted_at', v_sub.converted_at,
    -- Three different windows are reported below, so each one names its own.
    'window_start', v_since,
    'surfaces_window', 'all_time',
    'allowance', jsonb_build_object(
      'period_start', v_period_start,
      'period_end', v_period_end,
      -- `personal`, `organization` or `none`. A workspace seat is metered out of
      -- the workspace pool, so the limits below are that pool, not this person's.
      'payer', v_ent ->> 'payer',
      'org_id', v_ent ->> 'org_id',
      'seats', (v_ent ->> 'seats')::int,
      'plan', v_ent ->> 'plan',
      'status', v_ent ->> 'status',
      'hours_unlimited', coalesce((v_ent ->> 'hours_are_unlimited')::boolean, false),
      'hours_used', round(coalesce((v_ent ->> 'consumed_seconds')::numeric, 0) / 3600.0, 2),
      -- Everything the plan grants for this period, top-ups already folded in —
      -- the same number `can_start_meeting` measures against.
      'hours_limit', round(coalesce((v_ent ->> 'included_seconds')::numeric, 0) / 3600.0, 2),
      'credits_used', coalesce((v_ent ->> 'integration_credits_used')::numeric, 0),
      'credits_limit', coalesce((v_ent ->> 'integration_credits_included')::numeric, 0)
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
  'One user in full: the entitlement exactly as resolve_entitlement reports it (personal or workspace payer), spend by task and model, and which product surfaces they touch. Founder-gated.';
