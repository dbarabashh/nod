-- Founder dashboard metric fixes v3.
--
-- 1. last_active_at counted profiles.last_seen_at, which llm-proxy stamps on any
--    request *before* the entitlement gate — so a lapsed user whose app is still
--    running and getting 403s looked active forever. Activity now means a real
--    user action; the heartbeat is exposed separately as app_last_seen_at.
-- 2. subscriptions.status is never rewritten when a trial lapses (resolve_entitlement
--    derives 'expired' at call time), so 15 of 32 "trialing" rows were dead trials.
-- 3. new_paying_30d counted current_period_start, which moves on every renewal —
--    every existing subscriber re-entered the cohort monthly and deflated CAC.
-- 4. Cohort retention measured activity on the exact day N only; at cohort sizes of
--    1-7 users that reads as zero. Now day-1, then day 2-7 and day 8-30 windows.

alter table public.subscriptions add column if not exists converted_at timestamptz;

comment on column public.subscriptions.converted_at is
  'First time this subscription entered a paying status. Never moves on renewal.';

update public.subscriptions
   set converted_at = current_period_start
 where status in ('active', 'past_due') and converted_at is null;

create or replace function public.apply_paddle_subscription(
    p_user_id uuid,
    p_customer_id text,
    p_subscription_id text,
    p_price_id text,
    p_paddle_status text,
    p_period_start timestamptz,
    p_period_end timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan          text;
    v_existing_plan text;
    v_status        text;
begin
    select plan into v_plan from public.plan_prices where paddle_price_id = p_price_id;

    if v_plan is null then
        select plan into v_existing_plan from public.subscriptions where user_id = p_user_id;
        if v_existing_plan is not null then
            v_plan := v_existing_plan;
        elsif p_paddle_status in ('active', 'trialing') then
            raise exception 'apply_paddle_subscription: unmapped paddle price_id %', p_price_id;
        else
            return;
        end if;
    end if;

    v_status := case p_paddle_status
        when 'active'   then 'active'
        when 'trialing' then 'trialing'
        when 'past_due' then 'past_due'
        when 'paused'   then 'past_due'
        when 'canceled' then 'canceled'
        else 'past_due'
    end;

    insert into public.subscriptions as s (
        user_id, plan, status,
        current_period_start, current_period_end,
        paddle_customer_id, paddle_subscription_id, paddle_price_id,
        converted_at, updated_at
    ) values (
        p_user_id, v_plan, v_status,
        p_period_start, p_period_end,
        p_customer_id, p_subscription_id, p_price_id,
        case when v_status in ('active', 'past_due') then now() end,
        now()
    )
    on conflict (user_id) do update set
        plan                   = v_plan,
        status                 = v_status,
        current_period_start   = coalesce(p_period_start, s.current_period_start),
        current_period_end     = coalesce(p_period_end, s.current_period_end),
        paddle_customer_id     = coalesce(p_customer_id, s.paddle_customer_id),
        paddle_subscription_id = coalesce(p_subscription_id, s.paddle_subscription_id),
        paddle_price_id        = coalesce(p_price_id, s.paddle_price_id),
        converted_at           = case
                                   when v_status in ('active', 'past_due')
                                     then coalesce(s.converted_at, now())
                                   else s.converted_at
                                 end,
        updated_at             = now();
end;
$$;

create or replace function public._effective_sub_status(p_status text, p_trial_ends_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_status = 'trialing' and p_trial_ends_at is not null and now() > p_trial_ends_at
      then 'trial_expired'
    else p_status
  end;
$$;

create or replace function public._user_last_active(p_user_id uuid)
returns timestamptz
language sql
stable security definer
set search_path = 'public', 'auth'
as $$
  select greatest(
    (select max(created_at) from usage_events where user_id = p_user_id),
    (select max(created_at) from meetings where user_id = p_user_id and deleted_at is null),
    (select max(created_at) from chat_messages where user_id = p_user_id),
    (select last_sign_in_at from auth.users where id = p_user_id)
  );
$$;

grant execute on function public._effective_sub_status(text, timestamptz) to authenticated;
grant execute on function public._user_last_active(uuid) to authenticated;

create or replace function public.founder_metrics()
returns jsonb
language plpgsql
stable security definer
set search_path = 'public', 'auth'
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
    'active_users_7d', (select count(distinct user_id) from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'),
    'active_users_30d', (select count(distinct user_id) from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'),
    'total_meetings', (select count(*) from meetings where deleted_at is null and user_id <> all(excl)),
    'meetings_7d', (select count(*) from meetings where deleted_at is null and user_id <> all(excl) and created_at > now() - interval '7 days'),
    'voice_notes', (select count(*) from meetings where deleted_at is null and user_id <> all(excl) and kind = 'voice_note'),
    'media_items', (select count(*) from meetings where deleted_at is null and user_id <> all(excl) and kind = 'media'),
    'minutes_transcribed', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from usage_events where kind = 'transcribe' and user_id <> all(excl)),
    'minutes_transcribed_30d', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from usage_events where kind = 'transcribe' and user_id <> all(excl) and created_at > now() - interval '30 days'),
    'total_cost_usd', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events where user_id <> all(excl)),
    'cost_7d', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events where user_id <> all(excl) and created_at > now() - interval '7 days'),
    'cost_30d', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'),
    'chat_messages', (select count(*) from chat_messages where role = 'user' and user_id <> all(excl)),
    'error_rate_30d', (
      select case when count(*) = 0 then 0
        else round(count(*) filter (where status >= 400) * 100.0 / count(*), 2) end
      from usage_events where user_id <> all(excl) and created_at > now() - interval '30 days'
    ),
    'paying_users', (select count(*) from subscriptions s where s.status in ('active', 'past_due') and s.user_id <> all(excl)),
    'trialing_users', (select count(*) from subscriptions s
      where public._effective_sub_status(s.status, s.trial_ends_at) = 'trialing' and s.user_id <> all(excl)),
    'trial_expired_users', (select count(*) from subscriptions s
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
set search_path = 'public', 'auth'
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  eligible bigint; activated bigint; new_7d bigint; new_act_7d bigint;
  wk_last bigint; wk_retained bigint;
  paying bigint; trialing bigint; trial_expired bigint; churned bigint;
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

  select
    count(*) filter (where st in ('active', 'past_due')),
    count(*) filter (where st = 'trialing'),
    count(*) filter (where st = 'trial_expired'),
    count(*) filter (where st in ('canceled', 'expired'))
  into paying, trialing, trial_expired, churned
  from (select public._effective_sub_status(s.status, s.trial_ends_at) st
        from subscriptions s where s.user_id <> all(excl)) e;

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
    'pct_first_meeting_24h', (select case when count(*)=0 then 0 else round(count(*) filter (where h is not null and h<=24 and h>=0)*100.0/count(*),1) end
      from (select extract(epoch from (min(m.started_at)-u.created_at))/3600.0 h from auth.users u
        left join meetings m on m.user_id=u.id and m.deleted_at is null where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at) t),
    'never_recorded_count', (select count(*) from auth.users u where lower(u.email) <> all(excl_emails)
      and not exists (select 1 from meetings m where m.user_id=u.id and m.deleted_at is null)),
    'trial_to_paid_pct', case when (paying + trialing + trial_expired + churned) = 0 then 0
      else round(paying * 100.0 / (paying + trialing + trial_expired + churned), 1) end,
    'paying_users', paying,
    'trialing_users', trialing,
    'trial_expired_users', trial_expired,
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

create or replace function public.founder_monetization()
returns jsonb
language plpgsql
stable security definer
set search_path = 'public', 'auth'
as $$
declare
  result jsonb;
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
  paying bigint;
  trialing bigint;
  trial_expired bigint;
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

  select
    count(*) filter (where st in ('active', 'past_due')),
    count(*) filter (where st = 'trialing'),
    count(*) filter (where st = 'trial_expired'),
    count(*) filter (where st in ('canceled', 'expired'))
  into paying, trialing, trial_expired, churned
  from (select public._effective_sub_status(s.status, s.trial_ends_at) st
        from subscriptions s where s.user_id <> all(excl)) e;

  select count(*) into new_paying_30d from subscriptions
    where status in ('active','past_due') and user_id <> all(excl)
      and converted_at > now() - interval '30 days';

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
    'trial_expired_users', trial_expired,
    'churned_users', churned,
    'new_paying_30d', new_paying_30d,
    'trial_to_paid_pct', case when (paying + trialing + trial_expired + churned) = 0 then 0
      else round(paying * 100.0 / (paying + trialing + trial_expired + churned), 1) end,
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

create or replace function public.founder_plan_breakdown()
returns table(plan text, display_name text, status text, users bigint)
language plpgsql
stable security definer
set search_path = 'public', 'auth'
as $$
declare
  excl uuid[] := public._excluded_user_ids();
begin
  perform public._assert_founder();
  return query
  select s.plan, pl.display_name,
    public._effective_sub_status(s.status, s.trial_ends_at) as status,
    count(*)
  from subscriptions s
  left join plans pl on pl.plan = s.plan
  where s.user_id <> all(excl)
  group by s.plan, pl.display_name, public._effective_sub_status(s.status, s.trial_ends_at), pl.sort_order
  order by pl.sort_order nulls last, 3;
end;
$$;

create or replace function public.founder_users()
returns table(user_id uuid, email text, display_name text, created_at timestamptz,
  last_active_at timestamptz, app_version text, os_version text, plan text,
  sub_status text, trial_ends_at timestamptz, meetings_count bigint,
  minutes_transcribed numeric, cost_usd numeric, chat_count bigint, devices_count bigint)
language plpgsql
stable security definer
set search_path = 'public', 'auth'
as $$
begin
  perform public._assert_founder();
  return query
  select
    u.id, u.email::text, p.display_name, u.created_at,
    public._user_last_active(u.id) as last_active_at,
    p.app_version, p.os_version, s.plan,
    public._effective_sub_status(s.status, s.trial_ends_at), s.trial_ends_at,
    (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null),
    coalesce((select round(sum(ue.audio_seconds) / 60.0, 1) from usage_events ue where ue.user_id = u.id and ue.kind = 'transcribe'), 0),
    coalesce((select round(sum(ue.cost_usd), 4) from usage_events ue where ue.user_id = u.id), 0),
    (select count(*) from chat_messages cm where cm.user_id = u.id and cm.role = 'user'),
    (select count(*) from user_devices d where d.user_id = u.id)
  from auth.users u
  left join profiles p on p.user_id = u.id
  left join subscriptions s on s.user_id = u.id
  where lower(u.email) <> all(public._excluded_emails())
  order by last_active_at desc nulls last;
end;
$$;

create or replace function public.founder_user_notes_view()
returns table(user_id uuid, email text, display_name text, created_at timestamptz,
  plan text, sub_status text, meetings_count bigint, last_active_at timestamptz,
  who_they_are text, how_they_work text, why_chose text, requested text,
  last_feedback text, updated_at timestamptz)
language plpgsql
stable security definer
set search_path = 'public', 'auth'
as $$
begin
  perform public._assert_founder();
  return query
  select
    u.id, u.email::text, p.display_name, u.created_at,
    s.plan, public._effective_sub_status(s.status, s.trial_ends_at),
    (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null),
    public._user_last_active(u.id),
    n.who_they_are, n.how_they_work, n.why_chose, n.requested, n.last_feedback, n.updated_at
  from auth.users u
  left join profiles p on p.user_id = u.id
  left join subscriptions s on s.user_id = u.id
  left join founder_user_notes n on n.user_id = u.id
  where lower(u.email) <> all(public._excluded_emails())
  order by (n.updated_at is null), n.updated_at desc nulls last, u.created_at desc;
end;
$$;

drop function if exists public.founder_users_enriched(integer, integer);

create function public.founder_users_enriched(min_meetings integer default 2, window_days integer default 3)
returns table(user_id uuid, email text, display_name text, created_at timestamptz,
  last_active_at timestamptz, app_last_seen_at timestamptz, plan text, sub_status text,
  trial_ends_at timestamptz, meetings_count bigint, meetings_7d bigint, active_days_30d bigint,
  chat_count bigint, action_items_count bigint, shared_count bigint, minutes_transcribed numeric,
  cost_usd numeric, app_version text, os_version text, first_meeting_at timestamptz,
  activated boolean, segment text)
language plpgsql
stable security definer
set search_path = 'public', 'auth'
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
      public._effective_sub_status(s.status, s.trial_ends_at) as sub_status,
      s.trial_ends_at,
      (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null) as meetings_count,
      (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null and m.created_at > now() - interval '7 days') as meetings_7d,
      (select count(distinct ue.created_at::date) from usage_events ue where ue.user_id = u.id and ue.created_at > now() - interval '30 days') as active_days_30d,
      (select count(*) from chat_messages cm where cm.user_id = u.id and cm.role = 'user') as chat_count,
      (select count(*) from action_items ai where ai.user_id = u.id and ai.deleted_at is null) as action_items_count,
      (select count(*) from meeting_shares ms where ms.created_by = u.id and ms.revoked_at is null) as shared_count,
      coalesce((select round(sum(ue.audio_seconds) / 60.0, 1) from usage_events ue where ue.user_id = u.id and ue.kind = 'transcribe'), 0) as minutes_transcribed,
      coalesce((select round(sum(ue.cost_usd), 4) from usage_events ue where ue.user_id = u.id), 0) as cost_usd,
      p.app_version, p.os_version,
      (select min(m.started_at) from meetings m where m.user_id = u.id and m.deleted_at is null) as first_meeting_at,
      (select count(*) >= min_meetings from meetings m where m.user_id = u.id and m.deleted_at is null and m.ended_at is not null
        and m.created_at between u.created_at and u.created_at + make_interval(days => window_days)) as activated
    from auth.users u
    left join profiles p on p.user_id = u.id
    left join subscriptions s on s.user_id = u.id
    where lower(u.email) <> all(public._excluded_emails())
  )
  select b.id, b.email, b.display_name, b.created_at, b.last_active_at, b.app_last_seen_at,
    b.plan, b.sub_status, b.trial_ends_at,
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

grant execute on function public.founder_users_enriched(integer, integer) to authenticated;

-- Day-N retention on the exact day only reads as zero at cohort sizes of 1-7.
-- d1 = returned on day 1, d7 = returned on days 2-7, d30 = returned on days 8-30.
create or replace function public.founder_retention_cohorts(weeks integer default 8)
returns table(cohort_week date, cohort_size bigint, d1 numeric, d7 numeric, d30 numeric,
  d1_n bigint, d7_n bigint, d30_n bigint, d1_mature boolean, d7_mature boolean, d30_mature boolean)
language plpgsql
stable security definer
set search_path = 'public', 'auth'
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
      max(case when a.d between c.signup_day + 2 and c.signup_day + 7 then 1 else 0 end) as r7,
      max(case when a.d between c.signup_day + 8 and c.signup_day + 30 then 1 else 0 end) as r30
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
