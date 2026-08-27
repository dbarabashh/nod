alter table private.connector_oauth_config
    add column founder_mcp_enabled boolean not null default false;

alter table public.user_acquisition
    add column consent_revoked_at timestamptz,
    add column claimed_visitor_id uuid;

create index user_acquisition_claimed_visitor_idx
    on public.user_acquisition (claimed_visitor_id)
    where claimed_visitor_id is not null;

create function private.mark_user_acquisition_consent_revoked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.user_acquisition as acquisition
       set first_touch_id = null,
           last_touch_id = null,
           coverage_status = 'no_eligible_touch',
           consent_revoked_at = new.revoked_at
     where acquisition.claimed_visitor_id = new.visitor_id;
    return new;
end;
$$;

create trigger mark_user_acquisition_consent_revoked
after insert or update of revoked_at on public.acquisition_consent_revocations
for each row execute function private.mark_user_acquisition_consent_revoked();

revoke all on function private.mark_user_acquisition_consent_revoked() from public, anon, authenticated, mcp_connector;

create function private.backfill_user_acquisition_consent_revocations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_updated integer;
begin
    update public.user_acquisition as acquisition
       set claimed_visitor_id = coalesce(
           (
               select touch.visitor_id
                 from public.acquisition_touches as touch
                where touch.id = acquisition.last_touch_id
           ),
           (
               select touch.visitor_id
                 from public.acquisition_touches as touch
                where touch.id = acquisition.first_touch_id
           ),
           (
               select flow.visitor_id
                 from public.acquisition_auth_flows as flow
                where flow.claimed_by = acquisition.user_id
                  and flow.claimed_at = acquisition.claimed_at
                order by flow.relay_id
                limit 1
           )
       )
     where acquisition.claimed_visitor_id is null;

    with revoked_users as (
        select acquisition.user_id,
               revocation.revoked_at
          from public.user_acquisition as acquisition
          join public.acquisition_consent_revocations as revocation
            on revocation.visitor_id = acquisition.claimed_visitor_id
         where acquisition.consent_revoked_at is null
    )
    update public.user_acquisition as acquisition
       set first_touch_id = null,
           last_touch_id = null,
           coverage_status = 'no_eligible_touch',
           consent_revoked_at = revoked.revoked_at
      from revoked_users as revoked
     where acquisition.user_id = revoked.user_id
       and acquisition.consent_revoked_at is null;
    get diagnostics v_updated = row_count;
    return v_updated;
end;
$$;

select private.backfill_user_acquisition_consent_revocations();

drop function private.backfill_user_acquisition_consent_revocations();

create table private.founder_mcp_client_access (
    user_id uuid not null references auth.users(id) on delete cascade,
    client_id text not null check (client_id <> '' and length(client_id) <= 2048),
    resource_uri text not null check (resource_uri ~ '^https://[^[:space:]]+/mcp$'),
    primary key (user_id, client_id),
    granted_at timestamptz not null default now()
);

alter table private.founder_mcp_client_access enable row level security;

create policy founder_mcp_client_access_auth_hook
    on private.founder_mcp_client_access
    for select
    to supabase_auth_admin
    using (true);

revoke all on table private.founder_mcp_client_access from public, anon, authenticated, mcp_connector;
grant select on table private.founder_mcp_client_access to supabase_auth_admin;

create function public.connector_founder_analytics_client_access(p_client_ids text[])
returns table (
    client_id text,
    is_founder_client boolean,
    eligible boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_client_ids is null
       or cardinality(p_client_ids) > 100
       or array_position(p_client_ids, null) is not null then
        raise exception 'client ids must be a non-null array of at most 100 values' using errcode = '22023';
    end if;

    return query
    select candidate.client_id,
           exists (
               select 1
                 from private.founder_mcp_client_access as access
                where access.client_id = candidate.client_id
           ),
           exists (
               select 1
                 from private.founder_mcp_client_access as access
                where access.user_id = auth.uid()
                  and access.client_id = candidate.client_id
                  and exists (
                      select 1
                        from private.connector_oauth_config as config
                       where config.singleton
                         and config.founder_mcp_enabled
                  )
           )
      from unnest(p_client_ids) with ordinality as candidate(client_id, ordinality)
     order by candidate.ordinality;
end;
$$;

create or replace function public.connector_founder_analytics_eligible_clients(p_client_ids text[])
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_result text[];
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_client_ids is null
       or cardinality(p_client_ids) > 100
       or array_position(p_client_ids, null) is not null then
        raise exception 'client ids must be a non-null array of at most 100 values' using errcode = '22023';
    end if;

    select coalesce(array_agg(access.client_id), '{}'::text[])
      into v_result
      from public.connector_founder_analytics_client_access(p_client_ids) as access
     where access.eligible;

    return v_result;
end;
$$;

create or replace function public.connector_founder_analytics_eligibility(p_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select p_client_id is not null
       and p_client_id::text = any(
           public.connector_founder_analytics_eligible_clients(array[p_client_id::text])
       );
$$;

create function public.connector_founder_analytics_client_eligibility(p_client_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        auth.uid() is not null
        and p_client_id is not null
        and p_client_id = auth.jwt() ->> 'client_id'
        and auth.jwt() ->> 'role' = 'mcp_connector'
        and auth.jwt() ->> 'sub' = auth.uid()::text
        and jsonb_typeof(auth.jwt() -> 'nod_permissions') = 'array'
        and (auth.jwt() -> 'nod_permissions') ? 'founder_analytics:read'
        and exists (
            select 1
              from private.founder_mcp_client_access as access
             where access.user_id = auth.uid()
               and access.client_id = p_client_id
               and (
                   (jsonb_typeof(auth.jwt() -> 'aud') = 'string'
                       and auth.jwt() ->> 'aud' = access.resource_uri)
                   or (jsonb_typeof(auth.jwt() -> 'aud') = 'array'
                       and (auth.jwt() -> 'aud') ? access.resource_uri)
               )
        )
        and exists (
            select 1
              from private.connector_oauth_config as config
             where config.singleton
               and config.founder_mcp_enabled
        ),
        false
    );
$$;

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
    claims jsonb := event -> 'claims';
    subject_id uuid := coalesce(
        nullif(event ->> 'user_id', ''),
        nullif(event -> 'claims' ->> 'sub', '')
    )::uuid;
    meeting_resource_uri text;
    founder_resource_uri text;
    founder_mcp_enabled boolean;
    permissions jsonb := '[]'::jsonb;
begin
    if claims ->> 'client_id' is null then
        return event;
    end if;

    select config.resource_uri, config.founder_mcp_enabled
      into strict meeting_resource_uri, founder_mcp_enabled
      from private.connector_oauth_config as config
     where config.singleton;

    select access.resource_uri
      into founder_resource_uri
      from private.founder_mcp_client_access as access
     where access.user_id = subject_id
       and access.client_id = claims ->> 'client_id';

    if founder_resource_uri is not null then
        claims := jsonb_set(claims, '{aud}', to_jsonb(founder_resource_uri), true);
        if founder_mcp_enabled then
            permissions := '["founder_analytics:read"]'::jsonb;
        end if;
    elsif exists (
        select 1
          from private.founder_mcp_client_access as access
         where access.client_id = claims ->> 'client_id'
    ) then
        permissions := '[]'::jsonb;
    else
        claims := jsonb_set(claims, '{aud}', to_jsonb(meeting_resource_uri), true);
        permissions := '["meetings:read"]'::jsonb;
    end if;

    claims := jsonb_set(claims, '{role}', '"mcp_connector"'::jsonb, true);
    claims := jsonb_set(claims, '{nod_permissions}', permissions, true);

    return jsonb_build_object('claims', claims);
end;
$$;

create or replace function public._assert_founder_mcp()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if not public.connector_founder_analytics_client_eligibility(auth.jwt() ->> 'client_id') then
        raise exception 'not authorized' using errcode = '42501';
    end if;
end;
$$;

create table private.founder_mcp_rate_limits (
    actor_id uuid not null references auth.users(id) on delete cascade,
    client_id text not null,
    bucket text not null check (bucket in ('request', 'tool')),
    window_started_at timestamptz not null,
    request_count integer not null check (request_count > 0),
    primary key (actor_id, client_id, bucket)
);

alter table private.founder_mcp_rate_limits enable row level security;
revoke all on table private.founder_mcp_rate_limits from public, anon, authenticated, mcp_connector;

create function public.founder_mcp_take_rate_limit(p_bucket text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    v_actor_id uuid := auth.uid();
    v_client_id text := auth.jwt() ->> 'client_id';
    v_now timestamptz := clock_timestamp();
    v_limit integer;
    v_count integer;
    v_window_started_at timestamptz;
begin
    perform public._assert_founder_mcp();

    if p_bucket = 'request' then
        v_limit := 60;
    elsif p_bucket = 'tool' then
        v_limit := 30;
    else
        raise exception 'unknown rate-limit bucket' using errcode = '22023';
    end if;

    insert into private.founder_mcp_rate_limits (
        actor_id,
        client_id,
        bucket,
        window_started_at,
        request_count
    ) values (
        v_actor_id,
        v_client_id,
        p_bucket,
        v_now,
        1
    )
    on conflict (actor_id, client_id, bucket) do update
        set window_started_at = case
                when private.founder_mcp_rate_limits.window_started_at <= v_now - interval '1 minute'
                    then v_now
                else private.founder_mcp_rate_limits.window_started_at
            end,
            request_count = case
                when private.founder_mcp_rate_limits.window_started_at <= v_now - interval '1 minute'
                    then 1
                else private.founder_mcp_rate_limits.request_count + 1
            end
    returning request_count, window_started_at
         into v_count, v_window_started_at;

    return jsonb_build_object(
        'allowed', v_count <= v_limit,
        'limit', v_limit,
        'retry_after_seconds', case
            when v_count <= v_limit then 0
            else greatest(1, ceil(extract(epoch from (v_window_started_at + interval '1 minute' - v_now)))::integer)
        end
    );
end;
$$;

create function private.founder_recent_signups_data(
    p_days integer,
    p_limit integer,
    p_attribution_status text
)
returns table (
    user_id uuid,
    email text,
    display_name text,
    created_at timestamptz,
    plan text,
    subscription_status text,
    lifecycle_state text,
    first_meeting_at timestamptz,
    activated boolean,
    attribution_status text,
    source text,
    medium text,
    campaign_name text,
    referrer_host text,
    landing_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if p_days is null
       or p_limit is null
       or p_days not between 1 and 365
       or p_limit not between 1 and 100 then
        raise exception 'days must be 1..365 and limit must be 1..100' using errcode = '22023';
    end if;
    if p_attribution_status is not null
       and p_attribution_status not in ('attributed', 'unattributed') then
        raise exception 'attribution status must be attributed, unattributed, or null' using errcode = '22023';
    end if;

    return query
    with users as (
        select account.id,
               account.email::text,
               profile.display_name,
               account.created_at,
               subscription.plan,
               public._effective_sub_status(subscription.status, subscription.trial_ends_at) as subscription_status,
               public._user_last_active(account.id) as last_active_at,
               meeting_stats.first_completed_at,
               meeting_stats.completed_count,
               coalesce(meeting_stats.activated, false) as activated,
               acquisition.user_id as acquisition_user_id,
               acquisition.coverage_status,
               acquisition.claimed_visitor_id,
               acquisition.consent_revoked_at,
               touch.id as touch_id,
               touch.utm_source,
               touch.utm_medium,
               touch.utm_campaign,
               touch.referrer_host,
               touch.page_path,
               touch.gclid,
               touch.gbraid,
               touch.wbraid
          from auth.users as account
          left join public.profiles as profile on profile.user_id = account.id
          left join public.subscriptions as subscription on subscription.user_id = account.id
          left join public.user_acquisition as acquisition on acquisition.user_id = account.id
          left join public.acquisition_touches as touch on touch.id = acquisition.last_touch_id
          left join lateral (
              select completed.first_completed_at,
                     completed.completed_count,
                     exists (
                         select 1
                           from public.meetings as second_meeting
                          where second_meeting.user_id = account.id
                            and second_meeting.deleted_at is null
                            and second_meeting.ended_at > second_meeting.started_at
                            and second_meeting.ended_at > completed.first_completed_at
                            and second_meeting.ended_at <= completed.first_completed_at + interval '3 days'
                     ) as activated
                from (
                    select min(meeting.ended_at) as first_completed_at,
                           count(*) as completed_count
                      from public.meetings as meeting
                     where meeting.user_id = account.id
                       and meeting.deleted_at is null
                       and meeting.ended_at > meeting.started_at
                       and meeting.ended_at >= account.created_at
                ) as completed
          ) as meeting_stats on true
         where lower(account.email) <> all(public._excluded_emails())
           and account.created_at >= now() - make_interval(days => p_days)
    ), classified as (
        select users.*,
               case
                   when users.consent_revoked_at is not null then 'consent_revoked'
                   when users.acquisition_user_id is not null and users.claimed_visitor_id is null then 'unknown'
                   when users.coverage_status = 'attributed' and users.touch_id is not null then 'attributed'
                   else 'no_eligible_touch'
               end as resolved_attribution_status
          from users
    )
    select classified.id,
           classified.email,
           classified.display_name,
           classified.created_at,
           classified.plan,
           classified.subscription_status,
           case
               when classified.completed_count = 0 and classified.created_at > now() - interval '3 days' then 'new'
               when classified.completed_count = 0 then 'blocked'
               when classified.activated then 'activated'
               when classified.last_active_at > now() - interval '7 days' then 'active'
               else 'dormant'
           end,
           classified.first_completed_at,
           classified.activated,
           classified.resolved_attribution_status,
           case when classified.resolved_attribution_status = 'attributed'
               then coalesce(
                   classified.utm_source,
                   case when classified.gclid is not null or classified.gbraid is not null or classified.wbraid is not null then 'google' end,
                   nullif(classified.referrer_host, 'hellonod.app')
               ) end,
           case when classified.resolved_attribution_status = 'attributed'
               then coalesce(
                   classified.utm_medium,
                   case when classified.gclid is not null or classified.gbraid is not null or classified.wbraid is not null then 'cpc' end,
                   case when classified.referrer_host is not null and classified.referrer_host <> 'hellonod.app' then 'referral' end
               ) end,
           case when classified.resolved_attribution_status = 'attributed' then classified.utm_campaign end,
           case when classified.resolved_attribution_status = 'attributed' then nullif(classified.referrer_host, 'hellonod.app') end,
           case when classified.resolved_attribution_status = 'attributed' then classified.page_path end
      from classified
     where p_attribution_status is null
        or (p_attribution_status = 'attributed' and classified.resolved_attribution_status = 'attributed')
        or (p_attribution_status = 'unattributed' and classified.resolved_attribution_status <> 'attributed')
     order by classified.created_at desc
     limit p_limit;
end;
$$;

create or replace function public.founder_recent_signups(
    p_days integer default 30,
    p_limit integer default 50
)
returns table (
    user_id uuid,
    email text,
    display_name text,
    created_at timestamptz,
    plan text,
    subscription_status text,
    lifecycle_state text,
    first_meeting_at timestamptz,
    activated boolean,
    attribution_status text,
    source text,
    medium text,
    campaign_name text,
    referrer_host text,
    landing_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public._assert_founder();
    return query select * from private.founder_recent_signups_data(p_days, p_limit, null);
end;
$$;

create function public.founder_recent_signups(
    p_days integer,
    p_limit integer,
    p_attribution_status text
)
returns table (
    user_id uuid,
    email text,
    display_name text,
    created_at timestamptz,
    plan text,
    subscription_status text,
    lifecycle_state text,
    first_meeting_at timestamptz,
    activated boolean,
    attribution_status text,
    source text,
    medium text,
    campaign_name text,
    referrer_host text,
    landing_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public._assert_founder();
    return query select * from private.founder_recent_signups_data(
        p_days,
        p_limit,
        p_attribution_status
    );
end;
$$;

create function public.founder_user_attribution(p_user_ids uuid[])
returns table (
    user_id uuid,
    attribution_status text,
    source text,
    medium text,
    campaign_name text,
    referrer_host text,
    landing_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public._assert_founder();

    if p_user_ids is null
       or cardinality(p_user_ids) > 100
       or array_position(p_user_ids, null) is not null then
        raise exception 'user ids must be a non-null array of at most 100 values' using errcode = '22023';
    end if;

    return query
    select account.id,
           case
               when acquisition.consent_revoked_at is not null then 'consent_revoked'
               when acquisition.user_id is not null and acquisition.claimed_visitor_id is null then 'unknown'
               when acquisition.coverage_status = 'attributed' and touch.id is not null then 'attributed'
               else 'no_eligible_touch'
           end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
               then coalesce(
                   touch.utm_source,
                   case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'google' end,
                   nullif(touch.referrer_host, 'hellonod.app')
               ) end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
               then coalesce(
                   touch.utm_medium,
                   case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'cpc' end,
                   case when touch.referrer_host is not null and touch.referrer_host <> 'hellonod.app' then 'referral' end
               ) end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
               then touch.utm_campaign end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
               then nullif(touch.referrer_host, 'hellonod.app') end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
               then touch.page_path end
      from auth.users as account
      left join public.user_acquisition as acquisition on acquisition.user_id = account.id
      left join public.acquisition_touches as touch on touch.id = acquisition.last_touch_id
     where account.id = any(p_user_ids)
       and lower(account.email) <> all(public._excluded_emails());
end;
$$;

create or replace function public.claim_acquisition_flow(p_relay_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_visitor_id uuid;
    v_signup_at timestamptz;
    v_first_touch_id uuid;
    v_last_touch_id uuid;
    v_ga_client_id text;
    v_visitor_revoked_at timestamptz;
    v_effective_revoked_at timestamptz;
    v_existing_claim boolean := false;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select visitor_id
      into v_visitor_id
      from public.acquisition_auth_flows
     where relay_id = p_relay_id
       and expires_at > now()
       and (claimed_by is null or claimed_by = v_user_id)
     for update;

    if v_visitor_id is null then
        return jsonb_build_object('status', 'missing_or_expired');
    end if;

    select created_at into v_signup_at from auth.users where id = v_user_id;
    select revocation.revoked_at
      into v_visitor_revoked_at
      from public.acquisition_consent_revocations as revocation
     where revocation.visitor_id = v_visitor_id;

    if v_visitor_revoked_at is null then
        select id
          into v_first_touch_id
          from public.acquisition_touches
         where visitor_id = v_visitor_id
           and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
         order by occurred_at asc
         limit 1;

        select id, ga_client_id
          into v_last_touch_id, v_ga_client_id
          from public.acquisition_touches
         where visitor_id = v_visitor_id
           and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
         order by (
             utm_source is not null
             or gclid is not null
             or gbraid is not null
             or wbraid is not null
             or (referrer_host is not null and referrer_host <> 'hellonod.app')
         ) desc, occurred_at desc
         limit 1;
    end if;

    update public.acquisition_auth_flows
       set claimed_by = v_user_id,
           claimed_at = now()
     where relay_id = p_relay_id;

    select true
      into v_existing_claim
      from public.user_acquisition
     where user_id = v_user_id
     for update;
    v_existing_claim := coalesce(v_existing_claim, false);

    insert into public.user_acquisition (
        user_id,
        claimed_visitor_id,
        first_touch_id,
        last_touch_id,
        coverage_status,
        consent_revoked_at
    ) values (
        v_user_id,
        v_visitor_id,
        v_first_touch_id,
        v_last_touch_id,
        case
            when v_visitor_revoked_at is not null then 'no_eligible_touch'
            when v_last_touch_id is null then 'no_eligible_touch'
            else 'attributed'
        end,
        v_visitor_revoked_at
    )
    on conflict (user_id) do update
        set first_touch_id = case
                when public.user_acquisition.consent_revoked_at is not null
                  or excluded.consent_revoked_at is not null then null
                else public.user_acquisition.first_touch_id
            end,
            last_touch_id = case
                when public.user_acquisition.consent_revoked_at is not null
                  or excluded.consent_revoked_at is not null then null
                else public.user_acquisition.last_touch_id
            end,
            coverage_status = case
                when public.user_acquisition.consent_revoked_at is not null
                  or excluded.consent_revoked_at is not null then 'no_eligible_touch'
                else public.user_acquisition.coverage_status
            end,
            consent_revoked_at = coalesce(
                public.user_acquisition.consent_revoked_at,
                excluded.consent_revoked_at
            ),
            claimed_at = public.user_acquisition.claimed_at
    returning first_touch_id, last_touch_id, consent_revoked_at
         into v_first_touch_id, v_last_touch_id, v_effective_revoked_at;

    if v_effective_revoked_at is not null then
        v_first_touch_id := null;
        v_last_touch_id := null;
    elsif not v_existing_claim and v_last_touch_id is not null then
        insert into public.google_conversion_outbox (
            user_id,
            event,
            occurred_at,
            touch_id,
            ga_client_id
        ) values (
            v_user_id,
            'trial_started',
            v_signup_at,
            v_last_touch_id,
            v_ga_client_id
        )
        on conflict (user_id, event) do nothing;
    end if;

    return jsonb_build_object(
        'status', case
            when v_effective_revoked_at is not null then 'consent_revoked'
            when v_last_touch_id is null then 'no_eligible_touch'
            else 'attributed'
        end,
        'first_touch_id', v_first_touch_id,
        'last_touch_id', v_last_touch_id
    );
end;
$$;

create function public.founder_mcp_report(
    p_report text,
    p_days integer default 30,
    p_platform text default null,
    p_weeks integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_result jsonb;
    v_rows jsonb;
begin
    perform public._assert_founder_mcp();

    if p_report is null or p_report not in (
        'overview', 'acquisition', 'activation', 'retention', 'monetization',
        'usage_cost', 'product_analytics', 'communications'
    ) then
        raise exception 'unknown report' using errcode = '22023';
    end if;
    if p_days is null
       or p_weeks is null
       or p_days not between 1 and 365
       or p_weeks not between 1 and 52 then
        raise exception 'days must be 1..365 and weeks must be 1..52' using errcode = '22023';
    end if;
    if p_platform is not null and p_platform not in ('macos', 'ios') then
        raise exception 'platform must be macos, ios, or null' using errcode = '22023';
    end if;

    case p_report
        when 'overview' then
            v_result := jsonb_build_object(
                'report', p_report,
                'overview', public.founder_overview(2, 3),
                'totals', public.founder_metrics()
            );
        when 'acquisition' then
            v_result := jsonb_build_object(
                'report', p_report,
                'window_days', p_days,
                'summary', public.founder_acquisition(),
                'attribution', public.founder_acquisition_attribution(p_days)
            );
        when 'activation' then
            v_result := jsonb_build_object(
                'report', p_report,
                'window_days', p_days,
                'platform', p_platform,
                'summary', public.founder_activation(2, 3),
                'onboarding', public.founder_onboarding_activation(p_days, p_platform)
            );
        when 'retention' then
            select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
              into v_rows
              from public.founder_retention_cohorts(p_weeks) as row_data;
            v_result := jsonb_build_object(
                'report', p_report,
                'weeks', p_weeks,
                'engagement', public.founder_engagement(),
                'cohorts', v_rows
            );
        when 'monetization' then
            select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
              into v_rows
              from public.founder_plan_breakdown() as row_data;
            v_result := jsonb_build_object(
                'report', p_report,
                'summary', public.founder_monetization(),
                'plans', v_rows
            );
        when 'usage_cost' then
            select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
              into v_rows
              from public.founder_usage_breakdown() as row_data;
            v_result := jsonb_build_object('report', p_report, 'usage', v_rows);
            select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
              into v_rows
              from public.founder_model_breakdown() as row_data;
            v_result := v_result || jsonb_build_object('models', v_rows);
        when 'product_analytics' then
            v_result := jsonb_build_object(
                'report', p_report,
                'window_days', p_days,
                'platform', p_platform,
                'onboarding', public.founder_onboarding_activation(p_days, p_platform),
                'capture', public.founder_capture_reliability(p_days, p_platform),
                'value', public.founder_value_adoption(p_days, p_platform),
                'measurement_health', public.founder_measurement_health(least(p_days, 90))
            );
        when 'communications' then
            select coalesce(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
              into v_rows
              from public.founder_email_campaigns() as row_data;
            v_result := jsonb_build_object('report', p_report, 'campaigns', v_rows);
            select coalesce(jsonb_agg(to_jsonb(summary)), '[]'::jsonb)
              into v_rows
              from (
                  select outreach.campaign_key,
                         outreach.queue_status,
                         outreach.delivery_status,
                         count(*) as attempts,
                         count(*) filter (where outreach.converted_within_14d) as conversions
                    from public.founder_email_outreach() as outreach
                   group by outreach.campaign_key, outreach.queue_status, outreach.delivery_status
                   order by attempts desc
                   limit 100
              ) as summary;
            v_result := v_result || jsonb_build_object('delivery_summary', v_rows);
    end case;

    return v_result || jsonb_build_object(
        'generated_at', now(),
        'window_semantics', case
            when p_report in ('acquisition', 'activation', 'product_analytics') then 'days'
            when p_report = 'retention' then 'weeks'
            else 'all_time'
        end
    );
end;
$$;

create or replace function public.founder_mcp_recent_signups(
    p_days integer default 30,
    p_limit integer default 50,
    p_attribution_status text default null,
    p_include_identity boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_result jsonb;
begin
    perform public._assert_founder_mcp();

    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'user_key', 'user_' || substring(md5(signup.user_id::text) from 1 for 12),
               'email', case when p_include_identity then signup.email end,
               'display_name', case when p_include_identity then signup.display_name end,
               'created_at', signup.created_at,
               'plan', signup.plan,
               'subscription_status', signup.subscription_status,
               'lifecycle_state', signup.lifecycle_state,
               'first_meeting_at', signup.first_meeting_at,
               'activated', signup.activated,
               'attribution_status', signup.attribution_status,
               'source', signup.source,
               'medium', signup.medium,
               'campaign_name', signup.campaign_name,
               'referrer_host', signup.referrer_host,
               'landing_path', signup.landing_path
           )) order by signup.created_at desc), '[]'::jsonb)
      into v_result
      from private.founder_recent_signups_data(
          p_days,
          p_limit,
          p_attribution_status
      ) as signup;

    return jsonb_build_object(
        'window_days', p_days,
        'identity_included', p_include_identity,
        'signups', v_result,
        'generated_at', now()
    );
end;
$$;

create or replace function public.founder_mcp_find_user(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_query text := lower(trim(p_query));
    v_is_email boolean;
    v_is_uuid boolean;
    v_matches jsonb;
begin
    perform public._assert_founder_mcp();

    v_is_email := position('@' in v_query) > 1;
    v_is_uuid := v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
    if v_query is null
       or v_query = ''
       or length(v_query) > 120
       or (not v_is_email and not v_is_uuid and length(v_query) < 3) then
        raise exception 'query must be an exact email, user UUID, or a name of 3..120 characters' using errcode = '22023';
    end if;

    select coalesce(jsonb_agg(to_jsonb(match) - 'exact_email' order by match.exact_email desc, match.created_at desc), '[]'::jsonb)
      into v_matches
      from (
          select account.id as user_id,
                 account.email::text,
                 profile.display_name,
                 account.created_at,
                 subscription.plan,
                 public._effective_sub_status(subscription.status, subscription.trial_ends_at) as subscription_status,
                 public._user_last_active(account.id) as last_active_at,
                 (select count(*) from public.meetings as meeting where meeting.user_id = account.id and meeting.deleted_at is null) as meetings_count,
                 coalesce((select round(sum(event.audio_seconds) / 60.0, 1) from public.usage_events as event where event.user_id = account.id and event.kind = 'transcribe'), 0) as minutes_transcribed,
                 coalesce((select round(sum(event.cost_usd), 4) from public.usage_events as event where event.user_id = account.id), 0) as cost_usd,
                 coalesce((select count(*) from public.chat_messages as message where message.user_id = account.id and message.role = 'user'), 0) as chat_count,
                 case
                     when acquisition.consent_revoked_at is not null then 'consent_revoked'
                     when acquisition.user_id is not null and acquisition.claimed_visitor_id is null then 'unknown'
                     when acquisition.coverage_status = 'attributed' and touch.id is not null then 'attributed'
                     else 'no_eligible_touch'
                 end as attribution_status,
                 case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
                     then coalesce(
                         touch.utm_source,
                         case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'google' end,
                         nullif(touch.referrer_host, 'hellonod.app')
                     ) end as source,
                 case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
                     then coalesce(
                         touch.utm_medium,
                         case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'cpc' end,
                         case when touch.referrer_host is not null and touch.referrer_host <> 'hellonod.app' then 'referral' end
                     ) end as medium,
                 case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
                     then touch.utm_campaign end as campaign_name,
                 case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
                     then nullif(touch.referrer_host, 'hellonod.app') end as referrer_host,
                 case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null and acquisition.claimed_visitor_id is not null
                     then touch.page_path end as landing_path,
                 left(notes.who_they_are, 1000) as who_they_are,
                 left(notes.how_they_work, 1000) as how_they_work,
                 left(notes.why_chose, 1000) as why_chose,
                 left(notes.requested, 1000) as requested,
                 left(notes.last_feedback, 1000) as last_feedback,
                 lower(account.email) = v_query as exact_email
            from auth.users as account
            left join public.profiles as profile on profile.user_id = account.id
            left join public.subscriptions as subscription on subscription.user_id = account.id
            left join public.user_acquisition as acquisition on acquisition.user_id = account.id
            left join public.acquisition_touches as touch on touch.id = acquisition.last_touch_id
            left join public.founder_user_notes as notes on notes.user_id = account.id
           where lower(account.email) <> all(public._excluded_emails())
             and (
                 (v_is_email and lower(account.email) = v_query)
                 or (v_is_uuid and account.id::text = v_query)
                 or (
                     not v_is_email
                     and not v_is_uuid
                     and position(v_query in lower(coalesce(profile.display_name, ''))) > 0
                 )
             )
           order by exact_email desc, account.created_at desc
           limit 10
      ) as match;

    return jsonb_build_object('matches', v_matches, 'generated_at', now());
end;
$$;

create table private.founder_mcp_audit_events (
    id bigint generated always as identity primary key,
    occurred_at timestamptz not null default now(),
    actor_id uuid not null references auth.users(id) on delete cascade,
    client_id text not null,
    tool text not null check (tool in ('get_founder_report', 'list_recent_signups', 'find_user', 'unknown')),
    status text not null check (status in ('ok', 'error', 'rate_limited')),
    include_identity boolean,
    identity_query_length smallint check (identity_query_length between 0 and 120),
    returned_row_count integer not null check (returned_row_count >= 0)
);

alter table private.founder_mcp_audit_events enable row level security;
revoke all on table private.founder_mcp_audit_events from public, anon, authenticated, mcp_connector;
revoke all on sequence private.founder_mcp_audit_events_id_seq from public, anon, authenticated, mcp_connector;
create index founder_mcp_audit_events_occurred_at_idx
    on private.founder_mcp_audit_events (occurred_at);
create index founder_mcp_audit_events_rate_limited_idx
    on private.founder_mcp_audit_events (actor_id, client_id, occurred_at desc)
    where status = 'rate_limited';

create function public.founder_mcp_gateway(p_tool text, p_args jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    v_actor_id uuid := auth.uid();
    v_client_id text := auth.jwt() ->> 'client_id';
    v_audit_tool text := case
        when p_tool in ('get_founder_report', 'list_recent_signups', 'find_user') then p_tool
        else 'unknown'
    end;
    v_rate jsonb;
    v_result jsonb;
    v_status text := 'ok';
    v_include_identity boolean;
    v_identity_query_length integer;
    v_returned_row_count integer := 0;
    v_truncated boolean := false;
begin
    perform public._assert_founder_mcp();

    v_rate := public.founder_mcp_take_rate_limit('tool');
    if not coalesce((v_rate ->> 'allowed')::boolean, false) then
        v_status := 'rate_limited';
        v_result := jsonb_build_object(
            'error', 'rate_limited',
            'retry_after_seconds', (v_rate ->> 'retry_after_seconds')::integer
        );
    elsif p_args is null or jsonb_typeof(p_args) <> 'object' then
        v_status := 'error';
        v_result := jsonb_build_object('error', 'invalid_arguments');
    else
        begin
            case p_tool
                    when 'get_founder_report' then
                        if not p_args ? 'report'
                           or jsonb_typeof(p_args -> 'report') <> 'string'
                           or (p_args ? 'days' and (
                               jsonb_typeof(p_args -> 'days') <> 'number'
                               or p_args ->> 'days' !~ '^-?[0-9]+$'
                           ))
                           or (p_args ? 'weeks' and (
                               jsonb_typeof(p_args -> 'weeks') <> 'number'
                               or p_args ->> 'weeks' !~ '^-?[0-9]+$'
                           ))
                           or (p_args ? 'platform'
                               and jsonb_typeof(p_args -> 'platform') not in ('string', 'null'))
                           or p_args - array['report', 'days', 'platform', 'weeks'] <> '{}'::jsonb then
                            raise exception 'invalid arguments' using errcode = '22023';
                        end if;
                        if ((p_args ->> 'report') in ('overview', 'monetization', 'usage_cost', 'communications')
                                and p_args - 'report' <> '{}'::jsonb)
                           or ((p_args ->> 'report') = 'acquisition'
                                and p_args - array['report', 'days'] <> '{}'::jsonb)
                           or ((p_args ->> 'report') in ('activation', 'product_analytics')
                                and p_args - array['report', 'days', 'platform'] <> '{}'::jsonb)
                           or ((p_args ->> 'report') = 'retention'
                                and p_args - array['report', 'weeks'] <> '{}'::jsonb) then
                            raise exception 'irrelevant report arguments' using errcode = '22023';
                        end if;
                        v_result := public.founder_mcp_report(
                            p_args ->> 'report',
                            coalesce((p_args ->> 'days')::integer, 30),
                            nullif(p_args ->> 'platform', ''),
                            coalesce((p_args ->> 'weeks')::integer, 8)
                        );
                        v_returned_row_count := 1;
                    when 'list_recent_signups' then
                        if (p_args ? 'days' and (
                                jsonb_typeof(p_args -> 'days') <> 'number'
                                or p_args ->> 'days' !~ '^-?[0-9]+$'
                            ))
                           or (p_args ? 'limit' and (
                               jsonb_typeof(p_args -> 'limit') <> 'number'
                               or p_args ->> 'limit' !~ '^-?[0-9]+$'
                           ))
                           or (p_args ? 'attribution_status'
                               and jsonb_typeof(p_args -> 'attribution_status') not in ('string', 'null'))
                           or (p_args ? 'include_identity'
                               and jsonb_typeof(p_args -> 'include_identity') <> 'boolean')
                           or p_args - array['days', 'limit', 'attribution_status', 'include_identity'] <> '{}'::jsonb then
                            raise exception 'invalid arguments' using errcode = '22023';
                        end if;
                        v_include_identity := coalesce((p_args ->> 'include_identity')::boolean, false);
                        v_result := public.founder_mcp_recent_signups(
                            coalesce((p_args ->> 'days')::integer, 30),
                            coalesce((p_args ->> 'limit')::integer, 50),
                            nullif(p_args ->> 'attribution_status', ''),
                            v_include_identity
                        );
                        v_returned_row_count := coalesce(jsonb_array_length(v_result -> 'signups'), 0);
                    when 'find_user' then
                        if not p_args ? 'query'
                           or jsonb_typeof(p_args -> 'query') <> 'string'
                           or p_args - array['query'] <> '{}'::jsonb then
                            raise exception 'invalid arguments' using errcode = '22023';
                        end if;
                        v_identity_query_length := length(trim(p_args ->> 'query'));
                        v_result := public.founder_mcp_find_user(p_args ->> 'query');
                        v_returned_row_count := coalesce(jsonb_array_length(v_result -> 'matches'), 0);
                    else
                        raise exception 'unknown tool' using errcode = '22023';
            end case;
        exception
            when others then
                v_status := 'error';
                v_result := jsonb_build_object('error', 'invalid_arguments');
                v_include_identity := case when p_tool = 'list_recent_signups' then false end;
                v_identity_query_length := case when p_tool = 'find_user' then 0 end;
                v_returned_row_count := 0;
        end;
    end if;

    if v_status = 'ok' and octet_length(v_result::text) > 54000 then
        v_result := jsonb_build_object(
            'message', 'The report exceeded the safe response size. Request a narrower window or report.'
        );
        v_truncated := true;
    end if;

    delete from private.founder_mcp_audit_events
     where occurred_at < now() - interval '90 days';

    insert into private.founder_mcp_audit_events (
        actor_id,
        client_id,
        tool,
        status,
        include_identity,
        identity_query_length,
        returned_row_count
    )
    select
        v_actor_id,
        v_client_id,
        v_audit_tool,
        v_status,
        case when v_audit_tool = 'list_recent_signups' then coalesce(v_include_identity, false) end,
        case when v_audit_tool = 'find_user' then coalesce(v_identity_query_length, 0) end,
        v_returned_row_count
     where v_status <> 'rate_limited'
        or not exists (
            select 1
              from private.founder_mcp_audit_events as audit
             where audit.actor_id = v_actor_id
               and audit.client_id = v_client_id
               and audit.status = 'rate_limited'
               and audit.occurred_at >= now() - interval '1 minute'
        );

    if v_status <> 'ok' then
        return v_result;
    end if;

    return jsonb_build_object(
        'result', v_result,
        'truncated', v_truncated
    );
end;
$$;

grant usage on schema public to mcp_connector;

revoke all on function public.connector_founder_analytics_client_access(text[]) from public, anon, mcp_connector;
grant execute on function public.connector_founder_analytics_client_access(text[]) to authenticated;

revoke all on function public.connector_founder_analytics_eligible_clients(text[]) from public, anon, mcp_connector;
grant execute on function public.connector_founder_analytics_eligible_clients(text[]) to authenticated;

revoke all on function public.connector_founder_analytics_eligibility(uuid) from public, anon;
grant execute on function public.connector_founder_analytics_eligibility(uuid) to authenticated, mcp_connector;

revoke all on function public.connector_founder_analytics_client_eligibility(text) from public, anon;
grant execute on function public.connector_founder_analytics_client_eligibility(text) to authenticated, mcp_connector;

revoke all on function public.founder_mcp_take_rate_limit(text) from public, anon, authenticated;
grant execute on function public.founder_mcp_take_rate_limit(text) to mcp_connector;

revoke all on function public.founder_mcp_gateway(text, jsonb) from public, anon, authenticated;
grant execute on function public.founder_mcp_gateway(text, jsonb) to mcp_connector;

revoke all on function public.founder_mcp_report(text, integer, text, integer) from public, anon, authenticated, mcp_connector;
revoke all on function public.founder_mcp_recent_signups(integer, integer, text, boolean) from public, anon, authenticated, mcp_connector;
revoke all on function public.founder_mcp_find_user(text) from public, anon, authenticated, mcp_connector;

revoke all on function public.founder_user_attribution(uuid[]) from public, anon, mcp_connector;
grant execute on function public.founder_user_attribution(uuid[]) to authenticated;

revoke all on function public.founder_recent_signups(integer, integer, text) from public, anon, mcp_connector;
grant execute on function public.founder_recent_signups(integer, integer, text) to authenticated;

revoke all on function public.founder_recent_signups(integer, integer) from public, anon, mcp_connector;
grant execute on function public.founder_recent_signups(integer, integer) to authenticated;

revoke all on function private.founder_recent_signups_data(integer, integer, text) from public, anon, authenticated, mcp_connector;

revoke all on function public.custom_access_token_hook(jsonb) from public, anon, authenticated, mcp_connector;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

revoke all on function public._assert_founder_mcp() from public, anon, authenticated, mcp_connector;

drop function if exists public._founder_mcp_emails();

comment on table private.founder_mcp_client_access is
'Exact user UUID and OAuth client pairs allowed to receive and use the private founder analytics permission.';

comment on table private.founder_mcp_audit_events is
'Content-free founder MCP tool audit metadata retained for 90 days and pruned by gateway calls.';

comment on column private.connector_oauth_config.founder_mcp_enabled is
'Database kill switch for founder token issuance and gateway access. False is fail-closed.';
