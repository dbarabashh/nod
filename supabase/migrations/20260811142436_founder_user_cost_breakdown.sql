-- Per-user, per-model spend for the founder dashboard's cost page.
--
-- The existing metrics answer "what did we spend" and "who is active"; neither
-- answers "which user, on which model, at what cost" — which is the question a
-- rate limit or a model switch is actually decided on.
--
-- Unlike the product metrics, this does NOT exclude the founder accounts. The
-- page exists to answer "what does our own usage cost" as well as "what does a
-- customer cost" — on the sandbox branch the founders ARE all the traffic, and
-- excluding them returned an empty table. Internal rows are flagged instead, so
-- they can be told apart without being hidden.
--
-- Deliberately reads only columns that exist in BOTH production and the sandbox
-- branch. `task` / `resolved_model` were added on 2026-08-11 and have not
-- reached production, so grouping here is by the long-standing `model` column;
-- for transcribe rows that already carries the `provider:model` tag.

-- Dropped first: the signature gained `is_internal`, and Postgres refuses to
-- change an existing function's return type in place.
drop function if exists public.founder_user_costs(int);

create function public.founder_user_costs(p_days int default 30)
returns table (
  user_id uuid,
  email text,
  is_internal boolean,
  app_version text,
  os_version text,
  kind text,
  task text,
  model text,
  requests bigint,
  errors bigint,
  prompt_tokens bigint,
  completion_tokens bigint,
  audio_minutes numeric,
  cost_usd numeric,
  last_used_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  since timestamptz := now() - make_interval(days => greatest(p_days, 1));
begin
  perform public._assert_founder();
  return query
  select
    ue.user_id,
    u.email::text,
    lower(u.email) = any(public._founder_emails()),
    p.app_version,
    p.os_version,
    ue.kind,
    -- `task` (summary/title/utility/chat/stt) only exists where the routing
    -- telemetry migration has landed. Reading it through `to_jsonb` yields NULL
    -- instead of failing where the column is absent, so one function serves
    -- both production and the sandbox branch.
    to_jsonb(ue.*) ->> 'task',
    coalesce(ue.model, 'unknown'),
    count(*),
    count(*) filter (where ue.status < 200 or ue.status >= 300),
    coalesce(sum(ue.prompt_tokens), 0)::bigint,
    coalesce(sum(ue.completion_tokens), 0)::bigint,
    coalesce(round(sum(ue.audio_seconds) / 60.0, 1), 0),
    coalesce(round(sum(ue.cost_usd), 6), 0),
    max(ue.created_at)
  from usage_events ue
  join auth.users u on u.id = ue.user_id
  left join profiles p on p.user_id = ue.user_id
  where ue.created_at >= since
  group by ue.user_id, u.email, p.app_version, p.os_version, ue.kind,
           to_jsonb(ue.*) ->> 'task', coalesce(ue.model, 'unknown')
  order by coalesce(round(sum(ue.cost_usd), 6), 0) desc;
end;
$$;

revoke all on function public.founder_user_costs(int) from public, anon;
grant execute on function public.founder_user_costs(int) to authenticated;
