drop function if exists public.founder_users_enriched(integer, integer);
create function public.founder_users_enriched(min_meetings integer default 2, window_days integer default 3)
returns table(user_id uuid, email text, display_name text, created_at timestamptz,
  last_active_at timestamptz, app_last_seen_at timestamptz, plan text, billing_cycle text,
  sub_status text, trial_ends_at timestamptz, meetings_count bigint, meetings_7d bigint,
  active_days_30d bigint, chat_count bigint, action_items_count bigint, shared_count bigint,
  minutes_transcribed numeric, cost_usd numeric, app_version text, os_version text,
  first_meeting_at timestamptz, activated boolean, segment text)
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
      pp.billing_cycle,
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
    left join plan_prices pp on pp.paddle_price_id = s.paddle_price_id and pp.kind = 'subscription'
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
revoke all on function public.founder_users_enriched(integer, integer) from public, anon;
grant execute on function public.founder_users_enriched(integer, integer) to authenticated;
