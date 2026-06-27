-- Founder dashboard analytics — applied to the PRODUCTION Supabase project
-- (ref lptqvnizjwglilgeukwx) as migrations:
--   founder_dashboard_analytics_rpcs
--   founder_dashboard_exclude_employees
--
-- Kept here so the dashboard repo is self-documenting and the SQL is reviewable.
-- All functions are SECURITY DEFINER (bypass RLS to aggregate across every user)
-- but self-gate on the founder email allowlist, so the public publishable/anon key
-- grants no access on its own — only a logged-in founder JWT does. EXECUTE is granted
-- to `authenticated` only (revoked from anon/public) as defense in depth.

-- ---------- Gate ----------

create or replace function public.is_founder()
returns boolean
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = any (
    array['dmytro@hellonod.app', 'viktoriia@hellonod.app']
  );
$$;

create or replace function public._founder_emails()
returns text[]
language sql
immutable
as $$
  select array['dmytro@hellonod.app', 'viktoriia@hellonod.app'];
$$;

create or replace function public._assert_founder()
returns void
language plpgsql
stable
as $$
begin
  if not public.is_founder() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

-- ---------- KPIs (employees excluded from user counts) ----------

create or replace function public.founder_metrics()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  founders text[] := public._founder_emails();
begin
  perform public._assert_founder();
  select jsonb_build_object(
    'total_users', (select count(*) from auth.users where lower(email) <> all(founders)),
    'new_users_7d', (select count(*) from auth.users where lower(email) <> all(founders) and created_at > now() - interval '7 days'),
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(founders) and created_at > now() - interval '30 days'),
    'active_users_7d', (select count(distinct user_id) from usage_events where created_at > now() - interval '7 days'),
    'active_users_30d', (select count(distinct user_id) from usage_events where created_at > now() - interval '30 days'),
    'total_meetings', (select count(*) from meetings where deleted_at is null),
    'meetings_7d', (select count(*) from meetings where deleted_at is null and created_at > now() - interval '7 days'),
    'voice_notes', (select count(*) from meetings where deleted_at is null and kind = 'voice_note'),
    'media_items', (select count(*) from meetings where deleted_at is null and kind = 'media'),
    'minutes_transcribed', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from usage_events where kind = 'transcribe'),
    'minutes_transcribed_30d', (select coalesce(round(sum(audio_seconds) / 60.0, 1), 0) from usage_events where kind = 'transcribe' and created_at > now() - interval '30 days'),
    'total_cost_usd', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events),
    'cost_7d', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events where created_at > now() - interval '7 days'),
    'cost_30d', (select coalesce(round(sum(cost_usd), 2), 0) from usage_events where created_at > now() - interval '30 days'),
    'chat_messages', (select count(*) from chat_messages where role = 'user'),
    'error_rate_30d', (
      select case when count(*) = 0 then 0
        else round(count(*) filter (where status >= 400) * 100.0 / count(*), 2) end
      from usage_events where created_at > now() - interval '30 days'
    ),
    'paying_users', (select count(*) from subscriptions where status in ('active', 'past_due')),
    'trialing_users', (select count(*) from subscriptions where status = 'trialing'),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;

-- ---------- Per-user rollup ----------

create or replace function public.founder_users()
returns table (
  user_id uuid, email text, display_name text, created_at timestamptz,
  last_active_at timestamptz, app_version text, os_version text, plan text,
  sub_status text, trial_ends_at timestamptz, meetings_count bigint,
  minutes_transcribed numeric, cost_usd numeric, chat_count bigint, devices_count bigint
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select
    u.id, u.email::text, p.display_name, u.created_at,
    greatest(p.last_seen_at, u.last_sign_in_at, (select max(ue.created_at) from usage_events ue where ue.user_id = u.id)) as last_active_at,
    p.app_version, p.os_version, s.plan, s.status, s.trial_ends_at,
    (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null),
    coalesce((select round(sum(ue.audio_seconds) / 60.0, 1) from usage_events ue where ue.user_id = u.id and ue.kind = 'transcribe'), 0),
    coalesce((select round(sum(ue.cost_usd), 4) from usage_events ue where ue.user_id = u.id), 0),
    (select count(*) from chat_messages cm where cm.user_id = u.id and cm.role = 'user'),
    (select count(*) from user_devices d where d.user_id = u.id)
  from auth.users u
  left join profiles p on p.user_id = u.id
  left join subscriptions s on s.user_id = u.id
  where lower(u.email) <> all(public._founder_emails())
  order by last_active_at desc nulls last;
end;
$$;

-- ---------- Time series ----------

create or replace function public.founder_signups_daily(days int default 30)
returns table (day date, signups bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select d::date, count(u.id)
  from generate_series(current_date - (days - 1), current_date, interval '1 day') d
  left join auth.users u on u.created_at::date = d::date and lower(u.email) <> all(public._founder_emails())
  group by d
  order by d;
end;
$$;

create or replace function public.founder_activity_daily(days int default 30)
returns table (day date, meetings bigint, minutes numeric, cost numeric, events bigint, errors bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  with series as (
    select d::date as day
    from generate_series(current_date - (days - 1), current_date, interval '1 day') d
  ),
  mt as (
    select created_at::date as day, count(*) c
    from meetings where deleted_at is null and created_at >= current_date - (days - 1)
    group by 1
  ),
  ue as (
    select created_at::date as day,
      coalesce(round(sum(audio_seconds) filter (where kind = 'transcribe') / 60.0, 1), 0) minutes,
      coalesce(round(sum(cost_usd), 4), 0) cost,
      count(*) events,
      count(*) filter (where status >= 400) errors
    from usage_events where created_at >= current_date - (days - 1)
    group by 1
  )
  select s.day, coalesce(mt.c, 0), coalesce(ue.minutes, 0),
    coalesce(ue.cost, 0), coalesce(ue.events, 0), coalesce(ue.errors, 0)
  from series s
  left join mt on mt.day = s.day
  left join ue on ue.day = s.day
  order by s.day;
end;
$$;

-- ---------- Breakdowns ----------

create or replace function public.founder_plan_breakdown()
returns table (plan text, display_name text, status text, users bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select s.plan, pl.display_name, s.status, count(*)
  from subscriptions s
  left join plans pl on pl.plan = s.plan
  group by s.plan, pl.display_name, s.status, pl.sort_order
  order by pl.sort_order nulls last, s.status;
end;
$$;

create or replace function public.founder_usage_breakdown()
returns table (kind text, events bigint, prompt_tokens bigint, completion_tokens bigint, minutes numeric, cost numeric)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select ue.kind, count(*),
    coalesce(sum(ue.prompt_tokens), 0)::bigint,
    coalesce(sum(ue.completion_tokens), 0)::bigint,
    coalesce(round(sum(ue.audio_seconds) / 60.0, 1), 0),
    coalesce(round(sum(ue.cost_usd), 4), 0)
  from usage_events ue
  group by ue.kind
  order by count(*) desc;
end;
$$;

create or replace function public.founder_model_breakdown()
returns table (model text, events bigint, cost numeric, error_rate numeric)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select ue.model, count(*),
    coalesce(round(sum(ue.cost_usd), 4), 0),
    round(count(*) filter (where ue.status >= 400) * 100.0 / count(*), 2)
  from usage_events ue
  group by ue.model
  order by count(*) desc;
end;
$$;

create or replace function public.founder_app_versions()
returns table (app_version text, os_version text, users bigint)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select p.app_version, p.os_version, count(*)
  from profiles p
  group by p.app_version, p.os_version
  order by count(*) desc;
end;
$$;

-- ---------- Grants ----------

do $$
declare fn text;
begin
  foreach fn in array array[
    'founder_metrics()', 'founder_users()', 'founder_signups_daily(int)',
    'founder_activity_daily(int)', 'founder_plan_breakdown()', 'founder_usage_breakdown()',
    'founder_model_breakdown()', 'founder_app_versions()'
  ] loop
    execute format('revoke all on function public.%s from public, anon;', fn);
    execute format('grant execute on function public.%s to authenticated;', fn);
  end loop;
end $$;
