
-- Parameterized activation: "min_meetings completed meetings within window_days of
-- signup". Completed = ended_at present. Replaces the old zero-arg version.
drop function if exists public.founder_activation();

create or replace function public.founder_activation(min_meetings int default 2, window_days int default 3)
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
  eligible bigint;      -- users old enough to have had the full activation window
  activated bigint;
begin
  perform public._assert_founder();
  select count(*) into total_users from auth.users where lower(email) <> all(excl_emails);
  select count(*) into eligible from auth.users
    where lower(email) <> all(excl_emails) and created_at <= now() - make_interval(days => window_days);
  select count(*) into activated from (
    select u.id
    from auth.users u
    join meetings m on m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails)
      and u.created_at <= now() - make_interval(days => window_days)
    group by u.id
    having count(*) >= min_meetings
  ) t;

  select jsonb_build_object(
    'def_min_meetings', min_meetings,
    'def_window_days', window_days,
    'total_users', total_users,
    'eligible_users', eligible,
    'activated_users', activated,
    'activation_rate', case when eligible = 0 then 0 else round(activated * 100.0 / eligible, 1) end,
    -- supporting activation signals (kept from the original)
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

-- P0 Overview: decision-oriented cards. Activation definition is parameterized so
-- the founder can toggle it in the UI while hunting for the event that best
-- predicts retention/paid.
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
  eligible bigint;
  activated bigint;
  new_7d bigint;
  new_act_7d bigint;      -- of last-7d signups, how many already hit the bar
  wk_this bigint;
  wk_last bigint;
  wk_retained bigint;
begin
  perform public._assert_founder();

  select count(*) into eligible from auth.users
    where lower(email) <> all(excl_emails) and created_at <= now() - make_interval(days => window_days);
  select count(*) into activated from (
    select u.id from auth.users u
    join meetings m on m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at <= now() - make_interval(days => window_days)
    group by u.id having count(*) >= min_meetings
  ) t;

  select count(*) into new_7d from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days';
  select count(*) into new_act_7d from (
    select u.id from auth.users u
    join meetings m on m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at > now() - interval '7 days'
    group by u.id having count(*) >= min_meetings
  ) t;

  -- weekly retained: of users active last week (usage), how many active again this week
  select count(distinct user_id) into wk_this from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days';
  select count(distinct user_id) into wk_last from usage_events where user_id <> all(excl)
    and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days';
  select count(*) into wk_retained from (
    select distinct user_id from usage_events where user_id <> all(excl)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'
    intersect
    select distinct user_id from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'
  ) t;

  select jsonb_build_object(
    'def_min_meetings', min_meetings,
    'def_window_days', window_days,
    'new_users_7d', new_7d,
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '30 days'),
    'new_users_prev_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'),
    'activation_rate', case when eligible = 0 then 0 else round(activated * 100.0 / eligible, 1) end,
    'activated_users', activated,
    'eligible_users', eligible,
    'new_activated_7d', new_act_7d,
    'weekly_retained_pct', case when wk_last = 0 then 0 else round(wk_retained * 100.0 / wk_last, 1) end,
    'weekly_retained_count', wk_retained,
    'weekly_base_count', wk_last,
    'median_meetings_per_active', (
      select coalesce(percentile_cont(0.5) within group (order by c), 0) from (
        select count(*) c from meetings where deleted_at is null and user_id <> all(excl) group by user_id
      ) t),
    'avg_meetings_per_active', (
      select round(coalesce(avg(c), 0)::numeric, 1) from (
        select count(*) c from meetings where deleted_at is null and user_id <> all(excl) group by user_id
      ) t),
    'meetings_dist', (
      select jsonb_object_agg(bucket, users) from (
        select bucket, count(*) users from (
          select u.id, case
            when coalesce(m.c,0) = 0 then 'b0'
            when coalesce(m.c,0) = 1 then 'b1'
            when coalesce(m.c,0) between 2 and 4 then 'b2_4'
            else 'b5' end as bucket
          from auth.users u
          left join (select user_id, count(*) c from meetings where deleted_at is null group by user_id) m on m.user_id = u.id
          where lower(u.email) <> all(excl_emails)
        ) z group by bucket
      ) t),
    'median_hours_to_first_meeting', (
      select round(coalesce(percentile_cont(0.5) within group (order by h), 0)::numeric, 1) from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at
        having extract(epoch from (min(m.started_at) - u.created_at)) >= 0
      ) t),
    'pct_first_meeting_24h', (
      select case when count(*) = 0 then 0 else round(count(*) filter (where h <= 24 and h >= 0) * 100.0 / count(*), 1) end
      from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails) group by u.id, u.created_at
      ) t),
    'never_recorded_count', (
      select count(*) from auth.users u
      where lower(u.email) <> all(excl_emails)
        and not exists (select 1 from meetings m where m.user_id = u.id and m.deleted_at is null)),
    'trial_to_paid_pct', (
      select case when (p + tr + ch) = 0 then 0 else round(p * 100.0 / (p + tr + ch), 1) end
      from (select
        (select count(*) from subscriptions where status in ('active','past_due') and user_id <> all(excl)) p,
        (select count(*) from subscriptions where status = 'trialing' and user_id <> all(excl)) tr,
        (select count(*) from subscriptions where status in ('canceled','expired') and user_id <> all(excl)) ch
      ) s),
    'paying_users', (select count(*) from subscriptions where status in ('active','past_due') and user_id <> all(excl)),
    'trialing_users', (select count(*) from subscriptions where status = 'trialing' and user_id <> all(excl)),
    'users_at_risk', (
      select count(*) from (
        select u.id from auth.users u
        join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails)
        group by u.id
        having count(*) >= 2
          and coalesce(max(m.created_at), 'epoch') < now() - interval '7 days'
          and not exists (select 1 from usage_events ue where ue.user_id = u.id and ue.created_at > now() - interval '7 days')
      ) t),
    'chat_adoption_pct', (
      select case when (select count(*) from auth.users where lower(email) <> all(excl_emails)) = 0 then 0
        else round((select count(distinct user_id) from chat_messages where role='user' and user_id <> all(excl))
          * 100.0 / (select count(*) from auth.users where lower(email) <> all(excl_emails)), 1) end),
    'action_item_adoption_pct', (
      select case when (select count(*) from auth.users where lower(email) <> all(excl_emails)) = 0 then 0
        else round((select count(distinct user_id) from action_items where deleted_at is null and user_id <> all(excl))
          * 100.0 / (select count(*) from auth.users where lower(email) <> all(excl_emails)), 1) end),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

do $$
begin
  execute 'revoke all on function public.founder_activation(int,int) from public, anon';
  execute 'grant execute on function public.founder_activation(int,int) to authenticated';
  execute 'revoke all on function public.founder_overview(int,int) from public, anon';
  execute 'grant execute on function public.founder_overview(int,int) to authenticated';
end $$;
