
-- Per-user rollup enriched with activation + a computed action segment, so the
-- dashboard can show "who to write to today" lists (high intent / at risk / blocked).
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
      when b.meetings_count >= 2 and (b.last_active_at is null or b.last_active_at < now() - interval '7 days') then 'at_risk'
      when coalesce(b.activated, false) and b.sub_status = 'trialing'
        and (b.chat_count > 0 or b.action_items_count > 0 or b.shared_count > 0) then 'high_intent'
      when b.last_active_at > now() - interval '7 days' then 'active'
      else 'dormant'
    end as segment
  from base b
  order by b.last_active_at desc nulls last;
end;
$$;

-- Active-days-per-user distribution (habit signal) over the last 30 days.
create or replace function public.founder_active_days_buckets()
returns table (bucket text, users bigint)
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
  select z.bucket, count(*)::bigint
  from (
    select case
      when d = 0 then 'd0'
      when d = 1 then 'd1'
      when d between 2 and 3 then 'd2_3'
      when d between 4 and 6 then 'd4_6'
      else 'd7plus' end as bucket
    from (
      select u.id, (select count(distinct ue.created_at::date) from usage_events ue
        where ue.user_id = u.id and ue.created_at > now() - interval '30 days') as d
      from auth.users u where lower(u.email) <> all(excl_emails)
    ) x
  ) z
  group by z.bucket;
end;
$$;

-- Core-action retention (recorded a meeting on day N) by weekly signup cohort, with
-- absolute counts alongside percentages — on a small base the % alone can mislead.
drop function if exists public.founder_retention_cohorts(int);
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
  -- core action = a meeting created that day
  act as (
    select distinct user_id, created_at::date as d
    from meetings where deleted_at is null
  ),
  flags as (
    select c.wk, c.user_id,
      max(case when a.d = c.signup_day + 1 then 1 else 0 end) as r1,
      max(case when a.d = c.signup_day + 7 then 1 else 0 end) as r7,
      max(case when a.d = c.signup_day + 30 then 1 else 0 end) as r30,
      min(c.signup_day) as signup_day
    from cohort c
    left join act a on a.user_id = c.user_id
    group by c.wk, c.user_id
  )
  select
    wk, count(*)::bigint,
    round(avg(r1) * 100, 1), round(avg(r7) * 100, 1), round(avg(r30) * 100, 1),
    sum(r1)::bigint, sum(r7)::bigint, sum(r30)::bigint,
    (min(signup_day) + 1 <= current_date), (min(signup_day) + 7 <= current_date), (min(signup_day) + 30 <= current_date)
  from flags group by wk order by wk;
end;
$$;

do $$
begin
  execute 'revoke all on function public.founder_users_enriched(int,int) from public, anon';
  execute 'grant execute on function public.founder_users_enriched(int,int) to authenticated';
  execute 'revoke all on function public.founder_active_days_buckets() from public, anon';
  execute 'grant execute on function public.founder_active_days_buckets() to authenticated';
  execute 'revoke all on function public.founder_retention_cohorts(int) from public, anon';
  execute 'grant execute on function public.founder_retention_cohorts(int) to authenticated';
end $$;
