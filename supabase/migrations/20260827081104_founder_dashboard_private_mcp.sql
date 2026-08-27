alter table private.connector_oauth_config
    add column founder_resource_uri text not null
        default 'https://nod-founder-dashboard.vercel.app/mcp'
        check (founder_resource_uri ~ '^https://[^[:space:]]+/mcp$'),
    add column founder_client_id uuid;

alter table public.user_acquisition
    add column consent_revoked_at timestamptz;

create or replace function public._founder_mcp_emails()
returns text[]
language sql
immutable
set search_path = ''
as $$
    select array['dmytro@hellonod.app', 'vlad@hellonod.app'];
$$;

create or replace function public.connector_founder_analytics_eligibility(p_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select lower(coalesce(auth.jwt() ->> 'email', '')) = any(public._founder_mcp_emails())
       and exists (
           select 1
             from private.connector_oauth_config as config
            where config.singleton
              and config.founder_client_id = p_client_id
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
    meeting_resource_uri text;
    founder_resource_uri text;
    founder_client_id uuid;
    permissions jsonb := '["meetings:read"]'::jsonb;
begin
    if claims ->> 'client_id' is null then
        return event;
    end if;

    select config.resource_uri, config.founder_resource_uri, config.founder_client_id
      into strict meeting_resource_uri, founder_resource_uri, founder_client_id
      from private.connector_oauth_config as config
     where config.singleton;

    if founder_client_id is not null
       and founder_resource_uri is not null
       and claims ->> 'client_id' = founder_client_id::text
       and lower(coalesce(claims ->> 'email', '')) = any(public._founder_mcp_emails()) then
        claims := jsonb_set(
            claims,
            '{aud}',
            to_jsonb(founder_resource_uri),
            true
        );
        permissions := '["founder_analytics:read"]'::jsonb;
    else
        claims := jsonb_set(claims, '{aud}', to_jsonb(meeting_resource_uri), true);
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
declare
    claims jsonb := auth.jwt();
    founder_resource_uri text;
    founder_client_id uuid;
    audiences jsonb := claims -> 'aud';
begin
    select config.founder_resource_uri, config.founder_client_id
      into strict founder_resource_uri, founder_client_id
      from private.connector_oauth_config as config
     where config.singleton;

    if claims ->> 'role' <> 'mcp_connector'
       or coalesce(claims ->> 'client_id', '') = ''
       or founder_client_id is null
       or claims ->> 'client_id' <> founder_client_id::text
       or coalesce(claims ->> 'sub', '') = ''
       or lower(coalesce(claims ->> 'email', '')) <> all(public._founder_mcp_emails())
       or not coalesce((claims -> 'nod_permissions') ? 'founder_analytics:read', false)
       or not (
           (jsonb_typeof(audiences) = 'array' and audiences ? founder_resource_uri)
           or (jsonb_typeof(audiences) = 'string' and claims ->> 'aud' = founder_resource_uri)
       ) then
        raise exception 'not authorized' using errcode = '42501';
    end if;
end;
$$;

create or replace function public.revoke_acquisition_consent(p_visitor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.acquisition_consent_revocations (visitor_id, revoked_at)
    values (p_visitor_id, now())
    on conflict (visitor_id) do update set revoked_at = excluded.revoked_at;

    update public.google_conversion_outbox as conversion
       set status = 'suppressed',
           last_error = 'analytics consent withdrawn'
      from public.acquisition_touches as touch
     where conversion.touch_id = touch.id
       and touch.visitor_id = p_visitor_id
       and conversion.status in ('pending', 'failed');

    update public.user_acquisition as acquisition
       set first_touch_id = null,
           last_touch_id = null,
           coverage_status = 'no_eligible_touch',
           consent_revoked_at = now()
     where exists (
         select 1
           from public.acquisition_touches as touch
          where touch.visitor_id = p_visitor_id
            and touch.id in (acquisition.first_touch_id, acquisition.last_touch_id)
     );

    delete from public.acquisition_touches
     where visitor_id = p_visitor_id;
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

    select id
      into v_first_touch_id
      from public.acquisition_touches
     where visitor_id = v_visitor_id
       and not exists (
           select 1 from public.acquisition_consent_revocations as revocation
            where revocation.visitor_id = v_visitor_id
       )
       and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
     order by occurred_at asc
     limit 1;

    select id, ga_client_id
      into v_last_touch_id, v_ga_client_id
      from public.acquisition_touches
     where visitor_id = v_visitor_id
       and not exists (
           select 1 from public.acquisition_consent_revocations as revocation
            where revocation.visitor_id = v_visitor_id
       )
       and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
     order by (
         utm_source is not null
         or gclid is not null
         or gbraid is not null
         or wbraid is not null
         or (referrer_host is not null and referrer_host <> 'hellonod.app')
     ) desc, occurred_at desc
     limit 1;

    update public.acquisition_auth_flows
       set claimed_by = v_user_id,
           claimed_at = now()
     where relay_id = p_relay_id;

    insert into public.user_acquisition (
        user_id,
        first_touch_id,
        last_touch_id,
        coverage_status,
        consent_revoked_at
    ) values (
        v_user_id,
        v_first_touch_id,
        v_last_touch_id,
        case when v_last_touch_id is null then 'no_eligible_touch' else 'attributed' end,
        null
    )
    on conflict (user_id) do update
        set first_touch_id = excluded.first_touch_id,
            last_touch_id = excluded.last_touch_id,
            coverage_status = excluded.coverage_status,
            consent_revoked_at = null,
            claimed_at = now();

    if v_last_touch_id is not null then
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
        'status', case when v_last_touch_id is null then 'no_eligible_touch' else 'attributed' end,
        'first_touch_id', v_first_touch_id,
        'last_touch_id', v_last_touch_id
    );
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

    if p_days not between 1 and 365 or p_limit not between 1 and 100 then
        raise exception 'days must be 1..365 and limit must be 1..100' using errcode = '22023';
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
               (select min(meeting.started_at)
                  from public.meetings as meeting
                 where meeting.user_id = account.id and meeting.deleted_at is null) as first_meeting_at,
               (select count(*) >= 2
                  from public.meetings as meeting
                 where meeting.user_id = account.id
                   and meeting.deleted_at is null
                   and meeting.ended_at is not null
                   and meeting.created_at between account.created_at and account.created_at + interval '3 days') as activated,
               (select count(*)
                  from public.meetings as meeting
                 where meeting.user_id = account.id and meeting.deleted_at is null) as meetings_count,
               acquisition.coverage_status,
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
         where lower(account.email) <> all(public._excluded_emails())
           and account.created_at >= now() - make_interval(days => p_days)
         order by account.created_at desc
         limit p_limit
    )
    select users.id,
           users.email,
           users.display_name,
           users.created_at,
           users.plan,
           users.subscription_status,
           case
               when users.meetings_count = 0 and users.created_at > now() - interval '3 days' then 'new'
               when users.meetings_count = 0 then 'blocked'
               when users.activated then 'activated'
               when users.last_active_at > now() - interval '7 days' then 'active'
               else 'dormant'
           end,
           users.first_meeting_at,
           coalesce(users.activated, false),
           case
               when users.consent_revoked_at is not null then 'consent_revoked'
               when users.coverage_status = 'attributed' and users.touch_id is not null then 'attributed'
               else 'no_eligible_touch'
           end,
           case when users.coverage_status = 'attributed' and users.touch_id is not null and users.consent_revoked_at is null
               then coalesce(
                   users.utm_source,
                   case when users.gclid is not null or users.gbraid is not null or users.wbraid is not null then 'google' end,
                   nullif(users.referrer_host, 'hellonod.app')
               ) end,
           case when users.coverage_status = 'attributed' and users.touch_id is not null and users.consent_revoked_at is null
               then coalesce(
                   users.utm_medium,
                   case when users.gclid is not null or users.gbraid is not null or users.wbraid is not null then 'cpc' end,
                   case when users.referrer_host is not null and users.referrer_host <> 'hellonod.app' then 'referral' end
               ) end,
           case when users.coverage_status = 'attributed' and users.touch_id is not null and users.consent_revoked_at is null
               then users.utm_campaign end,
           case when users.coverage_status = 'attributed' and users.touch_id is not null and users.consent_revoked_at is null
               then nullif(users.referrer_host, 'hellonod.app') end,
           case when users.coverage_status = 'attributed' and users.touch_id is not null and users.consent_revoked_at is null
               then users.page_path end
      from users;
end;
$$;

create or replace function public.founder_user_attribution()
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

    return query
    select account.id,
           case
               when acquisition.consent_revoked_at is not null then 'consent_revoked'
               when acquisition.coverage_status = 'attributed' and touch.id is not null then 'attributed'
               else 'no_eligible_touch'
           end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null
               then coalesce(
                   touch.utm_source,
                   case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'google' end,
                   nullif(touch.referrer_host, 'hellonod.app')
               ) end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null
               then coalesce(
                   touch.utm_medium,
                   case when touch.gclid is not null or touch.gbraid is not null or touch.wbraid is not null then 'cpc' end,
                   case when touch.referrer_host is not null and touch.referrer_host <> 'hellonod.app' then 'referral' end
               ) end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null
               then touch.utm_campaign end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null
               then nullif(touch.referrer_host, 'hellonod.app') end,
           case when acquisition.coverage_status = 'attributed' and touch.id is not null and acquisition.consent_revoked_at is null
               then touch.page_path end
      from auth.users as account
      left join public.user_acquisition as acquisition on acquisition.user_id = account.id
      left join public.acquisition_touches as touch on touch.id = acquisition.last_touch_id
     where lower(account.email) <> all(public._excluded_emails());
end;
$$;

create or replace function public.founder_mcp_report(
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

    if p_report not in (
        'overview', 'acquisition', 'activation', 'retention', 'monetization',
        'usage_cost', 'product_analytics', 'communications'
    ) then
        raise exception 'unknown report' using errcode = '22023';
    end if;
    if p_days not between 1 and 365 or p_weeks not between 1 and 52 then
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

    return v_result || jsonb_build_object('generated_at', now());
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

    if p_days not between 1 and 365 or p_limit not between 1 and 100 then
        raise exception 'days must be 1..365 and limit must be 1..100' using errcode = '22023';
    end if;
    if p_attribution_status is not null and p_attribution_status not in ('attributed', 'unattributed') then
        raise exception 'attribution status must be attributed, unattributed, or null' using errcode = '22023';
    end if;

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
      from public.founder_recent_signups(p_days, p_limit) as signup
     where p_attribution_status is null
        or (p_attribution_status = 'attributed' and signup.attribution_status = 'attributed')
        or (p_attribution_status = 'unattributed' and signup.attribution_status <> 'attributed');

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
    v_matches jsonb;
begin
    perform public._assert_founder_mcp();

    if v_query = '' or length(v_query) > 120 then
        raise exception 'query must contain 1..120 characters' using errcode = '22023';
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
                 attribution.attribution_status,
                 attribution.source,
                 attribution.medium,
                 attribution.campaign_name,
                 attribution.referrer_host,
                 attribution.landing_path,
                 left(notes.who_they_are, 1000) as who_they_are,
                 left(notes.how_they_work, 1000) as how_they_work,
                 left(notes.why_chose, 1000) as why_chose,
                 left(notes.requested, 1000) as requested,
                 left(notes.last_feedback, 1000) as last_feedback,
                 lower(account.email) = v_query as exact_email
            from auth.users as account
            left join public.profiles as profile on profile.user_id = account.id
            left join public.subscriptions as subscription on subscription.user_id = account.id
            left join public.founder_user_attribution() as attribution on attribution.user_id = account.id
            left join public.founder_user_notes as notes on notes.user_id = account.id
           where lower(account.email) <> all(public._excluded_emails())
             and (
                 lower(account.email) = v_query
                 or position(v_query in lower(account.email)) > 0
                 or position(v_query in lower(coalesce(profile.display_name, ''))) > 0
                 or account.id::text = v_query
             )
           order by exact_email desc, account.created_at desc
           limit 10
      ) as match;

    return jsonb_build_object('matches', v_matches, 'generated_at', now());
end;
$$;

grant usage on schema public to mcp_connector;

revoke all on function public._founder_mcp_emails() from public, anon, authenticated, mcp_connector;
grant execute on function public._founder_mcp_emails() to supabase_auth_admin;
revoke all on function public._assert_founder_mcp() from public, anon, authenticated, mcp_connector;
revoke all on function public.connector_founder_analytics_eligibility(uuid) from public, anon, mcp_connector;
grant execute on function public.connector_founder_analytics_eligibility(uuid) to authenticated;

revoke all on function public.founder_recent_signups(integer, integer) from public, anon, mcp_connector;
revoke all on function public.founder_user_attribution() from public, anon, mcp_connector;
grant execute on function public.founder_recent_signups(integer, integer) to authenticated;
grant execute on function public.founder_user_attribution() to authenticated;

revoke all on function public.founder_mcp_report(text, integer, text, integer) from public, anon, authenticated;
revoke all on function public.founder_mcp_recent_signups(integer, integer, text, boolean) from public, anon, authenticated;
revoke all on function public.founder_mcp_find_user(text) from public, anon, authenticated;
grant execute on function public.founder_mcp_report(text, integer, text, integer) to mcp_connector;
grant execute on function public.founder_mcp_recent_signups(integer, integer, text, boolean) to mcp_connector;
grant execute on function public.founder_mcp_find_user(text) to mcp_connector;

revoke all on function public.custom_access_token_hook(jsonb) from public, anon, authenticated, mcp_connector;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

comment on column private.connector_oauth_config.founder_resource_uri is
'Exact audience for the private founder analytics MCP. Set per environment before enabling the function.';

comment on column private.connector_oauth_config.founder_client_id is
'Exact OAuth client allowed to receive founder analytics claims. Leave null until consent copy and policies are live.';
