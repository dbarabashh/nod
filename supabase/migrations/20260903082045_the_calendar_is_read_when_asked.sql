-- The connected calendar is read when the app asks, not every ten minutes.
--
-- `20260815124210` swept every connected calendar through the Connect proxy
-- six times an hour, day and night, whether or not anyone was at their Mac:
-- 4,320 metered requests per calendar a month before pagination. Linear
-- NOD-136. Four things replace it:
--
--   * `claim_calendar_read` — one statement that takes the read if the floor
--     for the stated reason has passed and the month's budget is not spent.
--     The app and the daily sweep (or one person's two Macs) can ask in the
--     same second, and the whole point is that only one of them pays.
--   * `integration_proxy_requests` — a daily tally per person, provider and
--     purpose of every request that went through the proxy, so the spend can
--     be read per capability instead of inferred from a Connect invoice.
--   * `calendar_sweep_candidates` — the accounts the app has not asked about,
--     oldest first, so a sweep bounded to a page can never starve one of them.
--   * The `sync-calendars` job rescheduled to once a day, as a safety net.
--
-- `calendar_sync_state.synced_at` was already the stamp of the last attempt,
-- succeeded or not; it is now also what every floor is measured from.
--
-- All three functions are for the service role only. They take a user id as
-- an argument, so a grant to `authenticated` would let one account spend or
-- inspect another's; the role check inside is the first line, the grant the
-- second.

create table public.integration_proxy_requests (
    user_id   uuid not null references auth.users(id) on delete cascade,
    provider  text not null,
    purpose   text not null,
    day       date not null,
    requests  integer not null default 0,
    primary key (user_id, provider, purpose, day)
);

-- Nothing in the app reads it, and the founder reads it through the
-- production connection like the rest of the metering tables.
alter table public.integration_proxy_requests enable row level security;

create function public.count_proxy_request(p_user uuid, p_provider text, p_purpose text)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'service role required' using errcode = '42501';
    end if;

    insert into public.integration_proxy_requests (user_id, provider, purpose, day, requests)
    values (p_user, p_provider, p_purpose, (now() at time zone 'utc')::date, 1)
    on conflict (user_id, provider, purpose, day)
    do update set requests = public.integration_proxy_requests.requests + 1;
end;
$$;

revoke all on function public.count_proxy_request(uuid, text, text) from public;
grant execute on function public.count_proxy_request(uuid, text, text) to service_role;

-- 'read' when this call may read the calendar; 'floor' when the last read is
-- too recent; 'capped' when the month's budget of proxied calendar requests
-- is spent (`p_monthly_cap` null means no budget applies to this ask — a
-- recording starting). Stamps `synced_at` as part of taking the read, so a second caller
-- in the same instant finds the floor already running. The function then
-- re-stamps on completion, which is what keeps a failed read from being
-- retried faster than a successful one.
--
-- The budget counts requests, not reads — a calendar that paginates spends
-- more of it per read — because requests are what the proxy meters. Not under
-- one lock with the claim: a handful of concurrent callers at the last request
-- of the month can each pass, and that overshoot is bounded by the floors.
create function public.claim_calendar_read(
    p_user uuid,
    p_provider text,
    p_calendar text,
    p_floor_seconds integer,
    p_monthly_cap integer
)
    returns text
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_spent integer;
    v_claimed boolean;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'service role required' using errcode = '42501';
    end if;

    select coalesce(sum(requests), 0) into v_spent
      from public.integration_proxy_requests
     where user_id = p_user
       and provider = p_provider
       and purpose like 'calendar-%'
       and day >= date_trunc('month', now() at time zone 'utc')::date;
    if p_monthly_cap is not null and v_spent >= p_monthly_cap then
        return 'capped';
    end if;

    insert into public.calendar_sync_state (user_id, provider, calendar_id, synced_at)
    values (p_user, p_provider, p_calendar, now())
    on conflict (user_id, provider, calendar_id) do update
        set synced_at = now()
      where public.calendar_sync_state.synced_at is null
         or public.calendar_sync_state.synced_at <= now() - make_interval(secs => p_floor_seconds)
    returning true into v_claimed;

    return case when coalesce(v_claimed, false) then 'read' else 'floor' end;
end;
$$;

revoke all on function public.claim_calendar_read(uuid, text, text, integer, integer) from public;
grant execute on function public.claim_calendar_read(uuid, text, text, integer, integer) to service_role;

-- Connected calendars the app has not asked about since `p_stale_before`,
-- the longest-unread first. Ordered before it is limited: a page cut from an
-- unordered list of every connection would fill with active accounts that
-- are never due, and the accounts past the page would never be swept.
create function public.calendar_sweep_candidates(
    p_provider text,
    p_calendar text,
    p_stale_before timestamptz,
    p_limit integer
)
    returns table (user_id uuid, broker_account_id text)
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'service role required' using errcode = '42501';
    end if;

    return query
    select c.user_id, c.broker_account_id
      from public.integration_connections c
      left join public.calendar_sync_state s
        on s.user_id = c.user_id
       and s.provider = c.provider
       and s.calendar_id = p_calendar
     where c.provider = p_provider
       and c.revoked_at is null
       and (s.synced_at is null or s.synced_at < p_stale_before)
     order by s.synced_at asc nulls first
     limit p_limit;
end;
$$;

revoke all on function public.calendar_sweep_candidates(text, text, timestamptz, integer) from public;
grant execute on function public.calendar_sweep_candidates(text, text, timestamptz, integer) to service_role;

-- Once a day, after the past-events purge, for whoever the app has not asked
-- about. `invoke_internal_edge_job` and its allowlist are unchanged. Looked up
-- rather than named, so a branch where the job was already removed by hand
-- does not fail the migration.
select cron.unschedule(jobid) from cron.job where jobname = 'sync-calendars';
select cron.schedule(
    'sync-calendars',
    '45 4 * * *',
    $$select public.invoke_internal_edge_job('calendar-sync')$$
);

-- The tally is metering, kept thirteen months so a year's cost can be read
-- against the year before it.
select cron.schedule(
    'purge-proxy-request-tallies',
    '51 4 * * *',
    $$delete from public.integration_proxy_requests where day < (now() at time zone 'utc')::date - 400$$
);
