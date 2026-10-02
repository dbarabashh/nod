-- Real usage excludes the welcome sample.
--
-- `seed_welcome_session()` (20260830160537) gives every new account one
-- meeting — ten minutes long, with six action items, one of them already
-- ticked — so the product has something to show before the first recording.
-- Its column comment says to exclude `origin = 'welcome'` from any count of
-- what a person actually recorded. Nothing did. Every founder RPC that counted
-- meetings, activation, retention or action items counted the sample, so a
-- person who signed in and never pressed record was "activated" and had
-- "completed an action item". On production, 2026-10-02, external accounts:
-- activated 76 → 68, users with a completed action item 32 → 12.
--
-- The rule, applied everywhere below: a RECORDED meeting is
-- `deleted_at is null and origin is null and ended_at > started_at`. An action
-- item counts when it belongs to a recorded meeting. A question counts when it
-- went to memory (`knowledge_messages`), to a recorded meeting's chat, or was
-- reported as `question_asked`. `summary_viewed` and `action_item_acted` events
-- carry no meeting id, so a view is counted only for a person who has a
-- recording — the sample's own summary cannot be told apart otherwise.
--
-- Stages are reported apart, not folded into one number:
-- `founder_activation_stages(window_days)` counts, over a signup cohort whose
-- window has fully elapsed, how many opened the app, made a first recording,
-- recorded again on another day, viewed a summary, asked memory, and completed
-- an action item from a real recording. `app_opened` exists only since the
-- client started sending `product_events` (2026-08); older cohorts read 0 and
-- `app_opened_tracked_since` says so. Nothing here reads the subscription's
-- current status: whoever signed up had trial access for the window, and
-- `trial_reactivated_users` says how many of the cohort were later given
-- another fourteen days (`trial_reactivations`).
--
-- The GA "activated" conversion (`enqueue_activation_conversion`) fired on the
-- sample too, because the seed inserts a positive-duration meeting within
-- seven days of signup. It now returns early for `origin is not null`.
--
-- "Asked" has one definition across these functions: a question in a recorded
-- meeting's chat, or a question to memory (`knowledge_messages`). The stages
-- function also accepts the `question_asked` event, which the client emits only
-- for memory asks, so an ask whose row failed to write still counts there.
--
-- Retention: `founder_retention_cohorts` reports a horizon only for a cohort
-- week that has closed and whose EVERY member has lived strictly past it
-- (`bool_and(signup_day + N < current_date)`). The open week and half-matured
-- horizons are `null`, which the dashboard renders as "—".
--
-- Still counting the sample after this migration, listed as follow-ups in the
-- playbook: `founder_acquisition`, `founder_acquisition_attribution`,
-- `founder_engagement`, `founder_users`, `founder_user_detail`,
-- `founder_activity_daily`, `founder_capture_reliability`,
-- `founder_recent_signups` / `founder_mcp_recent_signups`,
-- `founder_mcp_find_user`, `_user_last_active`, and `email_user_snapshots`
-- (lifecycle emails — a behaviour change for recipients, not a report).
--
-- Every rewritten function moves to `search_path = ''` with qualified names.
-- Signatures and return shapes are unchanged; only values move. Deploy the
-- migration before the dashboard (the stages card reads a function the old
-- schema does not have). Rollback: re-apply the previous bodies
-- (`20260723110215`, `20260710104623`, `20260710102849`, `20260808141022`,
-- `20260813072444`).

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
    if new.deleted_at is not null or new.origin is not null or new.ended_at <= new.started_at then
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

create or replace function public.founder_metrics()
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
begin
  perform public._assert_founder();
  select jsonb_build_object(
    'total_users', (select count(*) from auth.users where lower(email) <> all(excl_emails)),
    'new_users_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days'),
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '30 days'),
    'active_users_7d', (select count(distinct user_id) from public.usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'),
    'active_users_30d', (select count(distinct user_id) from public.usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'),
    'total_meetings', (select count(*) from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl)),
    'meetings_7d', (select count(*) from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl) and created_at > now() - interval '7 days'),
    'voice_notes', (select count(*) from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl) and kind = 'voice_note'),
    'media_items', (select count(*) from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl) and kind = 'media'),
    'minutes_transcribed', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from public.usage_events where kind = 'transcribe' and user_id <> all(excl)),
    'minutes_transcribed_30d', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from public.usage_events where kind = 'transcribe' and user_id <> all(excl) and created_at > now() - interval '30 days'),
    'total_cost_usd', (select coalesce(round(sum(cost_usd), 2), 0) from public.usage_events where user_id <> all(excl)),
    'cost_7d', (select coalesce(round(sum(cost_usd), 2), 0) from public.usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'),
    'cost_30d', (select coalesce(round(sum(cost_usd), 2), 0) from public.usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'),
    'chat_messages', (select count(*) from public.chat_messages cm
      join public.meetings m on m.id = cm.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      where cm.role = 'user' and cm.user_id <> all(excl)),
    'error_rate_30d', (
      select case when count(*) = 0 then 0
        else round(count(*) filter (where status >= 400) * 100.0 / count(*), 2) end
      from public.usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'
    ),
    'paying_users', (select count(*) from public.subscriptions s where s.status in ('active', 'past_due') and s.user_id <> all(excl)),
    'trialing_users', (select count(*) from public.subscriptions s
      where public._effective_sub_status(s.status, s.trial_ends_at) = 'trialing' and s.user_id <> all(excl)),
    'trial_expired_users', (select count(*) from public.subscriptions s
      where public._effective_sub_status(s.status, s.trial_ends_at) = 'trial_expired' and s.user_id <> all(excl)),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

create or replace function public.founder_overview(min_meetings integer default 2, window_days integer default 3)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  eligible bigint; activated bigint; new_7d bigint; new_act_7d bigint;
  wk_last bigint; wk_retained bigint;
  paying bigint; trialing bigint; trial_expired bigint; churned bigint;
  external_users bigint;
begin
  perform public._assert_founder();
  select count(*) into external_users from auth.users where lower(email) <> all(excl_emails);
  select count(*) into eligible from auth.users
    where lower(email) <> all(excl_emails) and created_at <= now() - make_interval(days => window_days);
  select count(*) into activated from (
    select u.id from auth.users u
    join public.meetings m on m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at <= now() - make_interval(days => window_days)
    group by u.id having count(*) >= min_meetings) t;
  select count(*) into new_7d from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days';
  select count(*) into new_act_7d from (
    select u.id from auth.users u
    join public.meetings m on m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)
    where lower(u.email) <> all(excl_emails) and u.created_at > now() - interval '7 days'
    group by u.id having count(*) >= min_meetings) t;
  select count(distinct user_id) into wk_last from public.usage_events where user_id <> all(excl)
    and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days';
  select count(*) into wk_retained from (
    select distinct user_id from public.usage_events where user_id <> all(excl)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'
    intersect
    select distinct user_id from public.usage_events where user_id <> all(excl) and created_at > now() - interval '7 days') t;

  select
    count(*) filter (where st in ('active', 'past_due')),
    count(*) filter (where st = 'trialing'),
    count(*) filter (where st = 'trial_expired'),
    count(*) filter (where st in ('canceled', 'expired'))
  into paying, trialing, trial_expired, churned
  from (select public._effective_sub_status(s.status, s.trial_ends_at) st
        from public.subscriptions s where s.user_id <> all(excl)) e;

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
      from (select count(*) c from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl) group by user_id) t),
    'avg_meetings_per_active', (select round(coalesce(avg(c), 0)::numeric, 1)
      from (select count(*) c from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl) group by user_id) t),
    'meetings_dist', (select jsonb_object_agg(bucket, users) from (
      select bucket, count(*) users from (
        select u.id, case when coalesce(m.c,0)=0 then 'b0' when coalesce(m.c,0)=1 then 'b1'
          when coalesce(m.c,0) between 2 and 4 then 'b2_4' else 'b5' end as bucket
        from auth.users u
        left join (select user_id, count(*) c from public.meetings where deleted_at is null and origin is null and ended_at > started_at group by user_id) m on m.user_id=u.id
        where lower(u.email) <> all(excl_emails)) z group by bucket) t),
    'median_hours_to_first_meeting', (select round(coalesce(percentile_cont(0.5) within group (order by h),0)::numeric,1)
      from (select extract(epoch from (min(m.started_at)-u.created_at))/3600.0 h from auth.users u
        join public.meetings m on m.user_id=u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at having extract(epoch from (min(m.started_at)-u.created_at)) >= 0) t),
    'pct_first_meeting_24h', (select case when count(*)=0 then 0 else round(count(*) filter (where h is not null and h<=24 and h>=0)*100.0/count(*),1) end
      from (select extract(epoch from (min(m.started_at)-u.created_at))/3600.0 h from auth.users u
        left join public.meetings m on m.user_id=u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at) t),
    'never_recorded_count', (select count(*) from auth.users u where lower(u.email) <> all(excl_emails)
      and not exists (select 1 from public.meetings m where m.user_id=u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at)),
    'trial_to_paid_pct', case when (paying + trialing + trial_expired + churned) = 0 then 0
      else round(paying * 100.0 / (paying + trialing + trial_expired + churned), 1) end,
    'paying_users', paying,
    'trialing_users', trialing,
    'trial_expired_users', trial_expired,
    'users_at_risk', (select count(*) from (
      select u.id from auth.users u join public.meetings m on m.user_id=u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      where lower(u.email) <> all(excl_emails) group by u.id
      having count(*) >= 2 and count(*) filter (where m.created_at > now() - interval '7 days') = 0) t),
    'chat_adoption_pct', case when external_users = 0 then 0
      else round((select count(distinct q.user_id) from (
                   select cm.user_id from public.chat_messages cm
                     join public.meetings m on m.id = cm.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
                     where cm.role = 'user'
                   union
                   select km.user_id from public.knowledge_messages km where km.role = 'user') q
                   where q.user_id <> all(excl))
        *100.0/external_users,1) end,
    'action_item_adoption_pct', case when external_users = 0 then 0
      else round((select count(distinct ai.user_id) from public.action_items ai
                   join public.meetings m on m.id = ai.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
                   where ai.deleted_at is null and ai.user_id <> all(excl))
        *100.0/external_users,1) end,
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

create or replace function public.founder_activation(min_meetings int default 2, window_days int default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
  eligible bigint;
  activated bigint;
begin
  perform public._assert_founder();
  select count(*) into total_users from auth.users where lower(email) <> all(excl_emails);
  select count(*) into eligible from auth.users
    where lower(email) <> all(excl_emails) and created_at <= now() - make_interval(days => window_days);
  select count(*) into activated from (
    select u.id
    from auth.users u
    join public.meetings m on m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
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
    'avg_meetings_first_7d', (
      select round(coalesce(avg(c), 0)::numeric, 2) from (
        select u.id, count(m.id) c
        from auth.users u
        left join public.meetings m on m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
          and m.created_at between u.created_at and u.created_at + interval '7 days'
        where lower(u.email) <> all(excl_emails)
        group by u.id
      ) t),
    'avg_meeting_minutes', (
      select round(coalesce(avg(extract(epoch from (ended_at - started_at)) / 60.0), 0)::numeric, 1)
      from public.meetings where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl)),
    'tried_chat_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct q.user_id) from (
          select cm.user_id from public.chat_messages cm
            join public.meetings m on m.id = cm.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
            where cm.role = 'user'
          union
          select km.user_id from public.knowledge_messages km where km.role = 'user') q
          where q.user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'shared_summary_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct ms.created_by) from public.meeting_shares ms
          join public.meetings m on m.id = ms.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
          join auth.users u on u.id = ms.created_by where lower(u.email) <> all(excl_emails))
        * 100.0 / total_users, 1) end),
    'action_items_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct ai.user_id) from public.action_items ai
          join public.meetings m on m.id = ai.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
          where ai.deleted_at is null and ai.user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'median_hours_to_first_meeting', (
      select round(coalesce(percentile_cont(0.5) within group (order by h), 0)::numeric, 1) from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join public.meetings m on m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
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
set search_path = ''
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
    (select count(distinct user_id) from public.meetings
      where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl))
  union all
  select 'Ran 2+ meetings', 3,
    (select count(*) from (
      select user_id from public.meetings
        where deleted_at is null and origin is null and ended_at > started_at and user_id <> all(excl)
      group by user_id having count(*) >= 2) t)
  union all
  select 'Tried AI chat', 4,
    (select count(distinct q.user_id) from (
      select cm.user_id from public.chat_messages cm
        join public.meetings m on m.id = cm.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
        where cm.role = 'user'
      union
      select km.user_id from public.knowledge_messages km where km.role = 'user') q
      where q.user_id <> all(excl))
  union all
  select 'Shared a summary', 5,
    (select count(distinct ms.created_by) from public.meeting_shares ms
      join public.meetings m on m.id = ms.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      join auth.users u on u.id = ms.created_by where lower(u.email) <> all(excl_emails))
  order by 2;
end;
$$;

create or replace function public.founder_retention_cohorts(weeks integer default 8)
returns table(cohort_week date, cohort_size bigint, d1 numeric, d7 numeric, d30 numeric,
  d1_n bigint, d7_n bigint, d30_n bigint, d1_mature boolean, d7_mature boolean, d30_mature boolean)
language plpgsql
stable security definer
set search_path = ''
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
    select distinct m.user_id, m.created_at::date as d
    from public.meetings m
    where m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
  ),
  flags as (
    select c.wk, c.user_id, c.signup_day,
      max(case when a.d = c.signup_day + 1 then 1 else 0 end) as r1,
      max(case when a.d between c.signup_day + 2 and c.signup_day + 7 then 1 else 0 end) as r7,
      max(case when a.d between c.signup_day + 8 and c.signup_day + 30 then 1 else 0 end) as r30
    from cohort c
    left join act a on a.user_id = c.user_id
    group by c.wk, c.user_id, c.signup_day
  ),
  per_week as (
    select wk, count(*)::bigint as n,
      (wk + 7 <= current_date and bool_and(signup_day + 1 < current_date)) as m1,
      (wk + 7 <= current_date and bool_and(signup_day + 7 < current_date)) as m7,
      (wk + 7 <= current_date and bool_and(signup_day + 30 < current_date)) as m30,
      round(avg(r1) * 100, 1) as p1, round(avg(r7) * 100, 1) as p7, round(avg(r30) * 100, 1) as p30,
      sum(r1)::bigint as n1, sum(r7)::bigint as n7, sum(r30)::bigint as n30
    from flags group by wk
  )
  select wk, n,
    case when m1 then p1 end, case when m7 then p7 end, case when m30 then p30 end,
    case when m1 then n1 end, case when m7 then n7 end, case when m30 then n30 end,
    m1, m7, m30
  from per_week order by wk;
end;
$$;

create or replace function public.founder_users_enriched(min_meetings integer default 2, window_days integer default 3)
returns table(user_id uuid, email text, display_name text, created_at timestamptz,
  last_active_at timestamptz, app_last_seen_at timestamptz, plan text, billing_cycle text,
  sub_status text, trial_ends_at timestamptz, meetings_count bigint, meetings_7d bigint,
  active_days_30d bigint, chat_count bigint, action_items_count bigint, shared_count bigint,
  minutes_transcribed numeric, cost_usd numeric, app_version text, os_version text,
  first_meeting_at timestamptz, activated boolean, segment text)
language plpgsql
stable security definer
set search_path = ''
as $$
begin
  perform public._assert_founder();
  return query
  with base as (
    select
      u.id, u.email::text as email, p.display_name, u.created_at,
      public._user_last_active(u.id) as last_active_at,
      p.last_seen_at as app_last_seen_at,
      s.plan,
      pp.billing_cycle,
      public._effective_sub_status(s.status, s.trial_ends_at) as sub_status,
      s.trial_ends_at,
      (select count(*) from public.meetings m where m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at) as meetings_count,
      (select count(*) from public.meetings m where m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at and m.created_at > now() - interval '7 days') as meetings_7d,
      (select count(distinct ue.created_at::date) from public.usage_events ue where ue.user_id = u.id and ue.created_at > now() - interval '30 days') as active_days_30d,
      (select count(*) from public.chat_messages cm
         join public.meetings m on m.id = cm.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
         where cm.user_id = u.id and cm.role = 'user')
      + (select count(*) from public.knowledge_messages km where km.user_id = u.id and km.role = 'user') as chat_count,
      (select count(*) from public.action_items ai
         join public.meetings m on m.id = ai.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
         where ai.user_id = u.id and ai.deleted_at is null) as action_items_count,
      (select count(*) from public.meeting_shares ms
         join public.meetings m on m.id = ms.meeting_id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
         where ms.created_by = u.id and ms.revoked_at is null) as shared_count,
      coalesce((select round(sum(ue.audio_seconds) / 60.0, 1) from public.usage_events ue where ue.user_id = u.id and ue.kind = 'transcribe'), 0) as minutes_transcribed,
      coalesce((select round(sum(ue.cost_usd), 4) from public.usage_events ue where ue.user_id = u.id), 0) as cost_usd,
      p.app_version, p.os_version,
      (select min(m.started_at) from public.meetings m where m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at) as first_meeting_at,
      (select count(*) >= min_meetings from public.meetings m
        where m.user_id = u.id and m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
          and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)) as activated
    from auth.users u
    left join public.profiles p on p.user_id = u.id
    left join public.subscriptions s on s.user_id = u.id
    left join public.plan_prices pp on pp.paddle_price_id = s.paddle_price_id and pp.kind = 'subscription'
    where lower(u.email) <> all(public._excluded_emails())
  )
  select b.id, b.email, b.display_name, b.created_at, b.last_active_at, b.app_last_seen_at,
    b.plan, b.billing_cycle, b.sub_status, b.trial_ends_at,
    b.meetings_count, b.meetings_7d, b.active_days_30d, b.chat_count, b.action_items_count, b.shared_count,
    b.minutes_transcribed, b.cost_usd, b.app_version, b.os_version,
    b.first_meeting_at, coalesce(b.activated, false),
    case
      when b.meetings_count = 0 and b.created_at > now() - interval '3 days' then 'new'
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

create or replace function public.founder_onboarding_activation(
    p_days integer default 30,
    p_platform text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
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
                     and m.origin is null
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
                     and m.origin is null
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

create or replace function public.founder_activation_stages(window_days integer default 14)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  excl_emails text[] := public._excluded_emails();
  v_window interval := make_interval(days => greatest(1, least(coalesce(window_days, 14), 90)));
  result jsonb;
begin
  perform public._assert_founder();

  with cohort as (
    select u.id as user_id, u.created_at as signed_up_at, u.created_at + v_window as window_end
    from auth.users u
    where lower(u.email) <> all(excl_emails)
      and u.created_at + v_window <= now()
  ),
  recorded as (
    select m.id, m.user_id, m.ended_at, (m.ended_at at time zone 'UTC')::date as day
    from public.meetings m
    join cohort c on c.user_id = m.user_id
    where m.deleted_at is null and m.origin is null and m.ended_at > m.started_at
      and m.ended_at >= c.signed_up_at and m.ended_at < c.window_end
  ),
  per_user as (
    select c.user_id,
      exists (select 1 from public.product_events pe
               where pe.user_id = c.user_id and pe.event = 'app_opened'
                 and pe.occurred_at >= c.signed_up_at and pe.occurred_at < c.window_end) as app_opened,
      exists (select 1 from recorded r where r.user_id = c.user_id) as first_recording,
      (select count(distinct r.day) from recorded r where r.user_id = c.user_id) >= 2 as repeat_day,
      exists (select 1 from recorded r where r.user_id = c.user_id)
        and exists (select 1 from public.product_events pe
                     where pe.user_id = c.user_id and pe.event = 'summary_viewed'
                       and pe.occurred_at >= c.signed_up_at and pe.occurred_at < c.window_end) as summary_viewed,
      (exists (select 1 from public.knowledge_messages km
                where km.user_id = c.user_id and km.role = 'user'
                  and km.created_at >= c.signed_up_at and km.created_at < c.window_end)
       or exists (select 1 from public.chat_messages cm
                   join recorded r on r.id = cm.meeting_id
                   where cm.user_id = c.user_id and cm.role = 'user'
                     and cm.created_at >= c.signed_up_at and cm.created_at < c.window_end)
       or exists (select 1 from public.product_events pe
                   where pe.user_id = c.user_id and pe.event = 'question_asked'
                     and pe.occurred_at >= c.signed_up_at and pe.occurred_at < c.window_end)) as asked_memory,
      (exists (select 1 from public.action_items ai
                join recorded r on r.id = ai.meeting_id
                where ai.user_id = c.user_id and ai.deleted_at is null and ai.done
                  and coalesce(ai.done_at, ai.updated_at) >= c.signed_up_at
                  and coalesce(ai.done_at, ai.updated_at) < c.window_end)
       or exists (select 1 from public.action_item_transitions t
                   join public.action_items ai on ai.id = t.action_item_id
                   join recorded r on r.id = ai.meeting_id
                   where t.user_id = c.user_id and t.actor = 'user' and t.to_state = 'confirmed'
                     and t.at >= c.signed_up_at and t.at < c.window_end)) as completed_action_item,
      exists (select 1 from public.trial_reactivations tr where tr.user_id = c.user_id) as trial_reactivated
    from cohort c
  )
  select jsonb_build_object(
    'window_days', extract(day from v_window)::int,
    'cohort_definition', 'signed_up_at_least_window_days_ago',
    'cohort_size', count(*),
    'trial_reactivated_users', count(*) filter (where trial_reactivated),
    'app_opened_tracked_since', (select min(pe.occurred_at) from public.product_events pe where pe.event = 'app_opened'),
    'stages', jsonb_build_object(
      'signed_up', count(*),
      'app_opened', count(*) filter (where app_opened),
      'first_recording', count(*) filter (where first_recording),
      'repeat_recording_other_day', count(*) filter (where repeat_day),
      'summary_viewed', count(*) filter (where summary_viewed),
      'asked_memory', count(*) filter (where asked_memory),
      'completed_action_item', count(*) filter (where completed_action_item)
    ),
    'generated_at', now()
  ) into result
  from per_user;

  return result;
end;
$$;

revoke all on function public.founder_activation_stages(integer) from public, anon;
grant execute on function public.founder_activation_stages(integer) to authenticated;
