
-- Fix 1: pct_first_meeting_24h now divides by ALL signups (left join) not just
--        recorders. Fix 2: users_at_risk aligned to the investor definition
--        (>=2 meetings AND no meeting in the last 7 days) — same as the enriched
--        at_risk segment below. Also drops the unused wk_this query.
create or replace function public.founder_overview(min_meetings int default 2, window_days int default 3)
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
  eligible bigint; activated bigint; new_7d bigint; new_act_7d bigint;
  wk_last bigint; wk_retained bigint;
begin
  perform public._assert_founder();
  select count(*) into eligible from auth.users
    where lower(email) <> all(excl_emails) and created_at <= now() - make_interval(days => window_days);
  select count(*) into activated from (
    select u.id from auth.users u
    join meetings m on m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at <= now() - make_interval(days => window_days)
    group by u.id having count(*) >= min_meetings) t;
  select count(*) into new_7d from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days';
  select count(*) into new_act_7d from (
    select u.id from auth.users u
    join meetings m on m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at > now() - interval '7 days'
    group by u.id having count(*) >= min_meetings) t;
  select count(distinct user_id) into wk_last from usage_events where user_id <> all(excl)
    and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days';
  select count(*) into wk_retained from (
    select distinct user_id from usage_events where user_id <> all(excl)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'
    intersect
    select distinct user_id from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days') t;

  select jsonb_build_object(
    'def_min_meetings', min_meetings, 'def_window_days', window_days,
    'new_users_7d', new_7d,
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '30 days'),
    'new_users_prev_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'),
    'activation_rate', case when eligible = 0 then 0 else round(activated * 100.0 / eligible, 1) end,
    'activated_users', activated, 'eligible_users', eligible, 'new_activated_7d', new_act_7d,
    'weekly_retained_pct', case when wk_last = 0 then 0 else round(wk_retained * 100.0 / wk_last, 1) end,
    'weekly_retained_count', wk_retained, 'weekly_base_count', wk_last,
    'median_meetings_per_active', (select coalesce(percentile_cont(0.5) within group (order by c), 0)
      from (select count(*) c from meetings where deleted_at is null and user_id <> all(excl) group by user_id) t),
    'avg_meetings_per_active', (select round(coalesce(avg(c), 0)::numeric, 1)
      from (select count(*) c from meetings where deleted_at is null and user_id <> all(excl) group by user_id) t),
    'meetings_dist', (select jsonb_object_agg(bucket, users) from (
      select bucket, count(*) users from (
        select u.id, case when coalesce(m.c,0)=0 then 'b0' when coalesce(m.c,0)=1 then 'b1'
          when coalesce(m.c,0) between 2 and 4 then 'b2_4' else 'b5' end as bucket
        from auth.users u
        left join (select user_id, count(*) c from meetings where deleted_at is null group by user_id) m on m.user_id=u.id
        where lower(u.email) <> all(excl_emails)) z group by bucket) t),
    'median_hours_to_first_meeting', (select round(coalesce(percentile_cont(0.5) within group (order by h),0)::numeric,1)
      from (select extract(epoch from (min(m.started_at)-u.created_at))/3600.0 h from auth.users u
        join meetings m on m.user_id=u.id and m.deleted_at is null where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at having extract(epoch from (min(m.started_at)-u.created_at)) >= 0) t),
    -- FIX: denominator is ALL signups (left join), never-recorded users count as "not within 24h"
    'pct_first_meeting_24h', (select case when count(*)=0 then 0 else round(count(*) filter (where h is not null and h<=24 and h>=0)*100.0/count(*),1) end
      from (select extract(epoch from (min(m.started_at)-u.created_at))/3600.0 h from auth.users u
        left join meetings m on m.user_id=u.id and m.deleted_at is null where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at) t),
    'never_recorded_count', (select count(*) from auth.users u where lower(u.email) <> all(excl_emails)
      and not exists (select 1 from meetings m where m.user_id=u.id and m.deleted_at is null)),
    'trial_to_paid_pct', (select case when (p+tr+ch)=0 then 0 else round(p*100.0/(p+tr+ch),1) end from (select
      (select count(*) from subscriptions where status in ('active','past_due') and user_id <> all(excl)) p,
      (select count(*) from subscriptions where status='trialing' and user_id <> all(excl)) tr,
      (select count(*) from subscriptions where status in ('canceled','expired') and user_id <> all(excl)) ch) s),
    'paying_users', (select count(*) from subscriptions where status in ('active','past_due') and user_id <> all(excl)),
    'trialing_users', (select count(*) from subscriptions where status='trialing' and user_id <> all(excl)),
    -- FIX: aligned to enriched at_risk segment — >=2 meetings AND none in last 7 days
    'users_at_risk', (select count(*) from (
      select u.id from auth.users u join meetings m on m.user_id=u.id and m.deleted_at is null
      where lower(u.email) <> all(excl_emails) group by u.id
      having count(*) >= 2 and count(*) filter (where m.created_at > now() - interval '7 days') = 0) t),
    'chat_adoption_pct', (select case when (select count(*) from auth.users where lower(email) <> all(excl_emails))=0 then 0
      else round((select count(distinct user_id) from chat_messages where role='user' and user_id <> all(excl))
        *100.0/(select count(*) from auth.users where lower(email) <> all(excl_emails)),1) end),
    'action_item_adoption_pct', (select case when (select count(*) from auth.users where lower(email) <> all(excl_emails))=0 then 0
      else round((select count(distinct user_id) from action_items where deleted_at is null and user_id <> all(excl))
        *100.0/(select count(*) from auth.users where lower(email) <> all(excl_emails)),1) end),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

-- Fix 3: at_risk segment now uses meeting recency (meetings_7d = 0), matching the
-- investor definition and the Overview users_at_risk card exactly.
create or replace function public.founder_users_enriched(min_meetings int default 2, window_days int default 3)
returns table (
  user_id uuid, email text, display_name text, created_at timestamptz, last_active_at timestamptz,
  plan text, sub_status text, trial_ends_at timestamptz,
  meetings_count bigint, meetings_7d bigint, active_days_30d bigint,
  chat_count bigint, action_items_count bigint, shared_count bigint,
  first_meeting_at timestamptz, activated boolean, segment text
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  with base as (
    select
      u.id, u.email::text as email, p.display_name, u.created_at,
      greatest(p.last_seen_at, u.last_sign_in_at, (select max(ue.created_at) from usage_events ue where ue.user_id = u.id)) as last_active_at,
      s.plan, s.status as sub_status, s.trial_ends_at,
      (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null) as meetings_count,
      (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null and m.created_at > now() - interval '7 days') as meetings_7d,
      (select count(distinct ue.created_at::date) from usage_events ue where ue.user_id = u.id and ue.created_at > now() - interval '30 days') as active_days_30d,
      (select count(*) from chat_messages cm where cm.user_id = u.id and cm.role = 'user') as chat_count,
      (select count(*) from action_items ai where ai.user_id = u.id and ai.deleted_at is null) as action_items_count,
      (select count(*) from meeting_shares ms where ms.created_by = u.id and ms.revoked_at is null) as shared_count,
      (select min(m.started_at) from meetings m where m.user_id = u.id and m.deleted_at is null) as first_meeting_at,
      (select count(*) >= min_meetings from meetings m where m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
        and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)) as activated
    from auth.users u
    left join profiles p on p.user_id = u.id
    left join subscriptions s on s.user_id = u.id
    where lower(u.email) <> all(public._excluded_emails())
  )
  select b.id, b.email, b.display_name, b.created_at, b.last_active_at, b.plan, b.sub_status, b.trial_ends_at,
    b.meetings_count, b.meetings_7d, b.active_days_30d, b.chat_count, b.action_items_count, b.shared_count,
    b.first_meeting_at, coalesce(b.activated, false),
    case
      when b.meetings_count = 0 then 'blocked'
      when b.meetings_count >= 2 and b.meetings_7d = 0 then 'at_risk'
      when coalesce(b.activated, false) and b.sub_status = 'trialing'
        and (b.chat_count > 0 or b.action_items_count > 0 or b.shared_count > 0) then 'high_intent'
      when b.last_active_at > now() - interval '7 days' then 'active'
      else 'dormant'
    end as segment
  from base b
  order by b.last_active_at desc nulls last;
end;
$$;

-- Fix 4: cohort retention denominators use per-user eligibility (only users whose
-- signup_day + N <= today count toward dN), so recent cohorts are no longer deflated
-- by members that haven't reached day N. Maturity is per-column (any eligible user).
create or replace function public.founder_retention_cohorts(weeks int default 8)
returns table (
  cohort_week date, cohort_size bigint,
  d1 numeric, d7 numeric, d30 numeric,
  d1_n bigint, d7_n bigint, d30_n bigint,
  d1_mature boolean, d7_mature boolean, d30_mature boolean
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  excl_emails text[] := public._excluded_emails();
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
  act as (
    select distinct user_id, created_at::date as d
    from meetings where deleted_at is null
  ),
  flags as (
    select c.wk, c.user_id, c.signup_day,
      max(case when a.d = c.signup_day + 1 then 1 else 0 end) as r1,
      max(case when a.d = c.signup_day + 7 then 1 else 0 end) as r7,
      max(case when a.d = c.signup_day + 30 then 1 else 0 end) as r30
    from cohort c
    left join act a on a.user_id = c.user_id
    group by c.wk, c.user_id, c.signup_day
  )
  select
    wk, count(*)::bigint,
    round(avg(r1) filter (where signup_day + 1 <= current_date) * 100, 1),
    round(avg(r7) filter (where signup_day + 7 <= current_date) * 100, 1),
    round(avg(r30) filter (where signup_day + 30 <= current_date) * 100, 1),
    coalesce(sum(r1) filter (where signup_day + 1 <= current_date), 0)::bigint,
    coalesce(sum(r7) filter (where signup_day + 7 <= current_date), 0)::bigint,
    coalesce(sum(r30) filter (where signup_day + 30 <= current_date), 0)::bigint,
    (count(*) filter (where signup_day + 1 <= current_date) > 0),
    (count(*) filter (where signup_day + 7 <= current_date) > 0),
    (count(*) filter (where signup_day + 30 <= current_date) > 0)
  from flags group by wk order by wk;
end;
$$;
