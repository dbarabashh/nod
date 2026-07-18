
create or replace function public.founder_acquisition()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
begin
  perform public._assert_founder();
  select count(*) into total_users from auth.users where lower(email) <> all(excl_emails);

  select jsonb_build_object(
    'total_users', total_users,
    'new_users_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days'),
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '30 days'),
    'new_users_prev_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'),
    'referred_users', (select count(distinct r.referee_user_id) from referrals r
      join auth.users u on u.id = r.referee_user_id where lower(u.email) <> all(excl_emails)),
    'organic_users', total_users - (select count(distinct r.referee_user_id) from referrals r
      join auth.users u on u.id = r.referee_user_id where lower(u.email) <> all(excl_emails)),
    'activated_users', (select count(distinct m.user_id) from meetings m
      where m.deleted_at is null and m.user_id <> all(excl)),
    'signup_to_meeting_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct m.user_id) from meetings m where m.deleted_at is null and m.user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'median_hours_to_first_meeting', (
      select round(coalesce(percentile_cont(0.5) within group (order by h), 0)::numeric, 1) from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at
        having extract(epoch from (min(m.started_at) - u.created_at)) >= 0
      ) t),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

create or replace function public.founder_activation()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
begin
  perform public._assert_founder();
  select count(*) into total_users from auth.users where lower(email) <> all(excl_emails);

  select jsonb_build_object(
    'total_users', total_users,
    'activated_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct m.user_id) from meetings m where m.deleted_at is null and m.user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'avg_meetings_first_7d', (
      select round(coalesce(avg(c), 0)::numeric, 2) from (
        select u.id, count(m.id) c
        from auth.users u
        left join meetings m on m.user_id = u.id and m.deleted_at is null
          and m.created_at between u.created_at and u.created_at + interval '7 days'
        where lower(u.email) <> all(excl_emails)
        group by u.id
      ) t),
    'avg_meeting_minutes', (
      select round(coalesce(avg(extract(epoch from (ended_at - started_at)) / 60.0), 0)::numeric, 1)
      from meetings where deleted_at is null and user_id <> all(excl) and ended_at > started_at),
    'tried_chat_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct user_id) from chat_messages where role = 'user' and user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'shared_summary_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct created_by) from meeting_shares ms
          join auth.users u on u.id = ms.created_by where lower(u.email) <> all(excl_emails))
        * 100.0 / total_users, 1) end),
    'action_items_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct user_id) from action_items where deleted_at is null and user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'median_hours_to_first_meeting', (
      select round(coalesce(percentile_cont(0.5) within group (order by h), 0)::numeric, 1) from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at
        having extract(epoch from (min(m.started_at) - u.created_at)) >= 0
      ) t),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

create or replace function public.founder_activation_funnel()
returns table (step text, sort int, users bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
begin
  perform public._assert_founder();
  return query
  select 'Signed up'::text, 1,
    (select count(*) from auth.users where lower(email) <> all(excl_emails))
  union all
  select 'Ran 1st meeting', 2,
    (select count(distinct user_id) from meetings where deleted_at is null and user_id <> all(excl))
  union all
  select 'Ran 2+ meetings', 3,
    (select count(*) from (
      select user_id from meetings where deleted_at is null and user_id <> all(excl)
      group by user_id having count(*) >= 2) t)
  union all
  select 'Tried AI chat', 4,
    (select count(distinct user_id) from chat_messages where role = 'user' and user_id <> all(excl))
  union all
  select 'Shared a summary', 5,
    (select count(distinct ms.created_by) from meeting_shares ms
      join auth.users u on u.id = ms.created_by where lower(u.email) <> all(excl_emails))
  order by 2;
end;
$$;

create or replace function public.founder_engagement()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  excl uuid[] := public._excluded_user_ids();
  dau bigint;
  mau bigint;
begin
  perform public._assert_founder();
  select count(distinct user_id) into dau from usage_events where user_id <> all(excl) and created_at > now() - interval '1 day';
  select count(distinct user_id) into mau from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days';

  select jsonb_build_object(
    'dau', dau,
    'wau', (select count(distinct user_id) from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'),
    'mau', mau,
    'stickiness_pct', (select case when mau = 0 then 0 else round(dau * 100.0 / mau, 1) end),
    'avg_meetings_per_active_7d', (
      select round(coalesce(
        (select count(*) from meetings where deleted_at is null and user_id <> all(excl) and created_at > now() - interval '7 days')::numeric
        / nullif((select count(distinct user_id) from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'), 0)
      , 0), 2)),
    'avg_meeting_minutes', (
      select round(coalesce(avg(extract(epoch from (ended_at - started_at)) / 60.0), 0)::numeric, 1)
      from meetings where deleted_at is null and user_id <> all(excl) and ended_at > started_at),
    'next_day_return_pct', (
      with days as (
        select distinct user_id, created_at::date as d
        from usage_events where user_id <> all(excl) and created_at > now() - interval '31 days'
      )
      select case when count(*) = 0 then 0 else round(
        count(*) filter (where exists (
          select 1 from days n where n.user_id = days.user_id and n.d = days.d + 1
        )) * 100.0 / count(*), 1) end
      from days where d < current_date
    ),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

create or replace function public.founder_retention_cohorts(weeks int default 8)
returns table (
  cohort_week date, cohort_size bigint,
  d1 numeric, d7 numeric, d30 numeric,
  d1_mature boolean, d7_mature boolean, d30_mature boolean
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
begin
  perform public._assert_founder();
  return query
  with cohort as (
    select u.id as user_id,
      date_trunc('week', u.created_at)::date as wk,
      u.created_at::date as signup_day
    from auth.users u
    where lower(u.email) <> all(excl_emails)
      and u.created_at >= date_trunc('week', now()) - (weeks - 1) * interval '1 week'
  ),
  ev as (
    select distinct user_id, created_at::date as d
    from usage_events where user_id <> all(excl)
  ),
  flags as (
    select c.wk, c.user_id,
      max(case when e.d = c.signup_day + 1 then 1 else 0 end) as r1,
      max(case when e.d = c.signup_day + 7 then 1 else 0 end) as r7,
      max(case when e.d = c.signup_day + 30 then 1 else 0 end) as r30,
      min(c.signup_day) as signup_day
    from cohort c
    left join ev e on e.user_id = c.user_id
    group by c.wk, c.user_id
  )
  select
    wk,
    count(*)::bigint as cohort_size,
    round(avg(r1) * 100, 1) as d1,
    round(avg(r7) * 100, 1) as d7,
    round(avg(r30) * 100, 1) as d30,
    (min(signup_day) + 1 <= current_date) as d1_mature,
    (min(signup_day) + 7 <= current_date) as d7_mature,
    (min(signup_day) + 30 <= current_date) as d30_mature
  from flags
  group by wk
  order by wk;
end;
$$;

create or replace function public.founder_monetization()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
  paying bigint;
  trialing bigint;
  churned bigint;
  mrr numeric;
  cost_30d numeric;
  active_30d bigint;
  spend numeric;
  lifetime_months numeric;
  new_paying_30d bigint;
  churn_rate numeric;
begin
  perform public._assert_founder();

  select count(*) into total_users from auth.users u where u.id <> all(excl);
  select count(*) into paying from subscriptions where status in ('active','past_due') and user_id <> all(excl);
  select count(*) into trialing from subscriptions where status = 'trialing' and user_id <> all(excl);
  select count(*) into churned from subscriptions where status in ('canceled','expired') and user_id <> all(excl);
  select count(*) into new_paying_30d from subscriptions
    where status in ('active','past_due') and user_id <> all(excl) and current_period_start > now() - interval '30 days';

  select coalesce(sum(
    coalesce(
      (select pp.display_amount from plan_prices pp where pp.paddle_price_id = s.paddle_price_id),
      (select pp.display_amount from plan_prices pp
        where pp.plan = s.plan and pp.kind = 'subscription' and pp.billing_cycle = 'monthly' and pp.active
        order by pp.sort_order limit 1)
    )
  ), 0) into mrr
  from subscriptions s where s.status in ('active','past_due') and s.user_id <> all(excl);

  select coalesce(round(sum(cost_usd), 2), 0) into cost_30d from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days';
  select count(distinct user_id) into active_30d from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days';

  select coalesce(marketing_spend_usd, 0), coalesce(assumed_lifetime_months, 12)
    into spend, lifetime_months from founder_manual_inputs where singleton;
  if spend is null then spend := 0; end if;
  if lifetime_months is null then lifetime_months := 12; end if;

  churn_rate := case when (paying + churned) = 0 then 0 else round(churned * 100.0 / (paying + churned), 1) end;

  select jsonb_build_object(
    'total_users', total_users,
    'paying_users', paying,
    'trialing_users', trialing,
    'churned_users', churned,
    'new_paying_30d', new_paying_30d,
    'trial_to_paid_pct', case when (paying + trialing + churned) = 0 then 0
      else round(paying * 100.0 / (paying + trialing + churned), 1) end,
    'churn_rate_pct', churn_rate,
    'mrr_usd', round(mrr, 2),
    'arr_usd', round(mrr * 12, 2),
    'arpu_usd', case when paying = 0 then 0 else round(mrr / paying, 2) end,
    'arpu_per_user_usd', case when total_users = 0 then 0 else round(mrr / total_users, 2) end,
    'ltv_est_usd', case
      when paying = 0 then 0
      when churn_rate > 0 then round((mrr / paying) / (churn_rate / 100.0), 2)
      else round((mrr / paying) * lifetime_months, 2) end,
    'ltv_basis', case when churn_rate > 0 then 'churn' else 'assumption' end,
    'lifetime_months_assumption', lifetime_months,
    'cost_30d_usd', cost_30d,
    'cogs_per_active_usd', case when active_30d = 0 then 0 else round(cost_30d / active_30d, 4) end,
    'gross_margin_pct', case when mrr = 0 then 0 else round((mrr - cost_30d) * 100.0 / mrr, 1) end,
    'marketing_spend_usd', round(spend, 2),
    'cac_usd', case when new_paying_30d = 0 then null else round(spend / new_paying_30d, 2) end,
    'ltv_cac_ratio', case when new_paying_30d = 0 or spend = 0 or paying = 0 then null
      else round(
        (case when churn_rate > 0 then (mrr / paying) / (churn_rate / 100.0) else (mrr / paying) * lifetime_months end)
        / (spend / new_paying_30d), 2) end,
    'generated_at', now()
  ) into result;
  return result;
end;
$$;
