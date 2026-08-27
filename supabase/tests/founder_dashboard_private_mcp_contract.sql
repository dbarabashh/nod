begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('10000000-0000-4000-8000-000000000101', 'vlad@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000102', 'dmytro@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000103', 'viktoriia@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000111', 'attributed@example.invalid', now() - interval '2 days', now()),
    ('10000000-0000-4000-8000-000000000112', 'unknown@example.invalid', now() - interval '3 days', now()),
    ('10000000-0000-4000-8000-000000000113', 'revoked@example.invalid', now() - interval '4 days', now()),
    ('10000000-0000-4000-8000-000000000114', 'dbarabashdev@gmail.com', now() - interval '1 day', now());

insert into public.acquisition_touches (
    id,
    visitor_id,
    session_id,
    occurred_at,
    event,
    page_path,
    page_group,
    referrer_host,
    utm_source,
    utm_medium,
    utm_campaign,
    consent_version
)
values
    (
        '20000000-0000-4000-8000-000000000111',
        '30000000-0000-4000-8000-000000000111',
        '40000000-0000-4000-8000-000000000111',
        now() - interval '3 days',
        'page_view',
        '/pricing',
        'pricing',
        'google.com',
        'google',
        'cpc',
        'founder-search',
        'web-v1'
    ),
    (
        '20000000-0000-4000-8000-000000000113',
        '30000000-0000-4000-8000-000000000113',
        '40000000-0000-4000-8000-000000000113',
        now() - interval '5 days',
        'page_view',
        '/chatgpt',
        'chatgpt',
        'example.com',
        'private-source',
        'referral',
        'must-disappear',
        'web-v1'
    );

insert into public.user_acquisition (
    user_id,
    first_touch_id,
    last_touch_id,
    coverage_status
)
values
    (
        '10000000-0000-4000-8000-000000000111',
        '20000000-0000-4000-8000-000000000111',
        '20000000-0000-4000-8000-000000000111',
        'attributed'
    ),
    (
        '10000000-0000-4000-8000-000000000112',
        null,
        null,
        'no_eligible_touch'
    ),
    (
        '10000000-0000-4000-8000-000000000113',
        '20000000-0000-4000-8000-000000000113',
        '20000000-0000-4000-8000-000000000113',
        'attributed'
    );

select public.revoke_acquisition_consent('30000000-0000-4000-8000-000000000113');

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"authenticated"}';

do $$
declare
    attributed record;
    unattributed record;
    revoked record;
begin
    select * into attributed
      from public.founder_recent_signups(30, 100)
     where email = 'attributed@example.invalid';
    if attributed.attribution_status <> 'attributed'
       or attributed.source <> 'google'
       or attributed.medium <> 'cpc'
       or attributed.campaign_name <> 'founder-search'
       or attributed.landing_path <> '/pricing' then
        raise exception 'attributed signup did not preserve consent-safe source fields: %', attributed;
    end if;

    select * into unattributed
      from public.founder_recent_signups(30, 100)
     where email = 'unknown@example.invalid';
    if unattributed.attribution_status <> 'no_eligible_touch'
       or unattributed.source is not null
       or unattributed.campaign_name is not null then
        raise exception 'unknown signup invented source fields: %', unattributed;
    end if;

    select * into revoked
      from public.founder_recent_signups(30, 100)
     where email = 'revoked@example.invalid';
    if revoked.attribution_status <> 'consent_revoked'
       or revoked.source is not null
       or revoked.medium is not null
       or revoked.campaign_name is not null
       or revoked.referrer_host is not null
       or revoked.landing_path is not null then
        raise exception 'revoked signup exposed attribution fields: %', revoked;
    end if;

    if exists (
        select 1 from public.founder_recent_signups(30, 100)
        where email = 'dbarabashdev@gmail.com'
    ) then
        raise exception 'internal account appeared in recent signups';
    end if;

    if not exists (
        select 1 from public.founder_user_attribution()
        where user_id = '10000000-0000-4000-8000-000000000111'
          and attribution_status = 'attributed'
          and source = 'google'
    ) then
        raise exception 'user attribution lookup lost its keyed source';
    end if;
end;
$$;

do $$
begin
    perform public.founder_recent_signups(0, 10);
    raise exception 'zero-day window unexpectedly succeeded';
exception
    when invalid_parameter_value then null;
end;
$$;

do $$
begin
    perform public.founder_recent_signups(30, 101);
    raise exception 'oversized recent-signup limit unexpectedly succeeded';
exception
    when invalid_parameter_value then null;
end;
$$;

reset role;
set local role anon;
set local request.jwt.claims = '{}';

do $$
begin
    perform public.founder_recent_signups(30, 10);
    raise exception 'anonymous recent-signup access unexpectedly succeeded';
exception
    when insufficient_privilege then null;
end;
$$;

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000111","email":"attributed@example.invalid","role":"authenticated"}';

do $$
begin
    perform public.founder_user_attribution();
    raise exception 'non-founder attribution access unexpectedly succeeded';
exception
    when insufficient_privilege then null;
end;
$$;

reset role;

update private.connector_oauth_config
   set founder_client_id = '50000000-0000-4000-8000-000000000001';

do $$
declare
    vlad_claims jsonb;
    dmytro_claims jsonb;
    viktoriia_claims jsonb;
    customer_claims jsonb;
    wrong_client_claims jsonb;
begin
    vlad_claims := public.custom_access_token_hook(jsonb_build_object(
        'claims', jsonb_build_object('client_id', '50000000-0000-4000-8000-000000000001', 'email', 'vlad@hellonod.app')
    )) -> 'claims';
    dmytro_claims := public.custom_access_token_hook(jsonb_build_object(
        'claims', jsonb_build_object('client_id', '50000000-0000-4000-8000-000000000001', 'email', 'dmytro@hellonod.app')
    )) -> 'claims';
    viktoriia_claims := public.custom_access_token_hook(jsonb_build_object(
        'claims', jsonb_build_object('client_id', '50000000-0000-4000-8000-000000000001', 'email', 'viktoriia@hellonod.app')
    )) -> 'claims';
    customer_claims := public.custom_access_token_hook(jsonb_build_object(
        'claims', jsonb_build_object('client_id', '50000000-0000-4000-8000-000000000001', 'email', 'attributed@example.invalid')
    )) -> 'claims';
    wrong_client_claims := public.custom_access_token_hook(jsonb_build_object(
        'claims', jsonb_build_object('client_id', '50000000-0000-4000-8000-000000000099', 'email', 'vlad@hellonod.app')
    )) -> 'claims';

    if not (vlad_claims -> 'nod_permissions' ? 'founder_analytics:read')
       or not (dmytro_claims -> 'nod_permissions' ? 'founder_analytics:read') then
        raise exception 'eligible founder token missed analytics permission';
    end if;
    if viktoriia_claims -> 'nod_permissions' ? 'founder_analytics:read'
       or customer_claims -> 'nod_permissions' ? 'founder_analytics:read'
       or wrong_client_claims -> 'nod_permissions' ? 'founder_analytics:read' then
        raise exception 'non-allowlisted token received analytics permission';
    end if;
    if vlad_claims ->> 'aud' <> 'https://nod-founder-dashboard.vercel.app/mcp'
       or vlad_claims -> 'nod_permissions' ? 'meetings:read'
       or jsonb_typeof(viktoriia_claims -> 'aud') <> 'string' then
        raise exception 'founder resource audience was not bound to the exact allowlist';
    end if;
end;
$$;

do $$
begin
    if has_table_privilege('mcp_connector', 'public.user_acquisition', 'SELECT')
       or has_table_privilege('mcp_connector', 'public.meetings', 'SELECT')
       or has_table_privilege('mcp_connector', 'public.founder_user_notes', 'SELECT') then
        raise exception 'mcp_connector unexpectedly has table access';
    end if;
    if has_function_privilege('mcp_connector', 'public.founder_metrics()', 'EXECUTE')
       or has_function_privilege('mcp_connector', 'public.founder_recent_signups(integer,integer)', 'EXECUTE')
       or not has_function_privilege('mcp_connector', 'public.founder_mcp_report(text,integer,text,integer)', 'EXECUTE')
       or not has_function_privilege('mcp_connector', 'public.founder_mcp_recent_signups(integer,integer,text,boolean)', 'EXECUTE')
       or not has_function_privilege('mcp_connector', 'public.founder_mcp_find_user(text)', 'EXECUTE') then
        raise exception 'mcp_connector function grants do not match the gateway-only contract';
    end if;
end;
$$;

set local role mcp_connector;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"mcp_connector","client_id":"50000000-0000-4000-8000-000000000001","aud":"https://nod-founder-dashboard.vercel.app/mcp","nod_permissions":["founder_analytics:read"]}';

do $$
declare
    pseudonymous jsonb;
    identified jsonb;
begin
    pseudonymous := public.founder_mcp_recent_signups(30, 100, null, false);
    identified := public.founder_mcp_recent_signups(30, 100, null, true);
    if pseudonymous::text like '%attributed@example.invalid%'
       or pseudonymous ->> 'identity_included' <> 'false' then
        raise exception 'default recent-signup response exposed identity: %', pseudonymous;
    end if;
    if identified::text not like '%attributed@example.invalid%'
       or identified ->> 'identity_included' <> 'true' then
        raise exception 'explicit identity request did not include identity: %', identified;
    end if;
    if jsonb_array_length(pseudonymous -> 'signups') > 100 then
        raise exception 'recent-signup response exceeded its row bound';
    end if;
    if public.founder_mcp_find_user('attributed@example.invalid')::text not like '%founder-search%' then
        raise exception 'explicit user lookup omitted lifecycle attribution';
    end if;
end;
$$;

reset role;
set local role mcp_connector;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000103","email":"viktoriia@hellonod.app","role":"mcp_connector","client_id":"50000000-0000-4000-8000-000000000001","aud":["https://nod-founder-dashboard.vercel.app/mcp"],"nod_permissions":["founder_analytics:read"]}';

do $$
begin
    perform public.founder_mcp_report('overview', 30, null, 8);
    raise exception 'dashboard-only founder unexpectedly reached private MCP data';
exception
    when insufficient_privilege then null;
end;
$$;

rollback;
