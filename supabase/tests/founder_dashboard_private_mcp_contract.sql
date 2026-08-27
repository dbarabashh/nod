begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('10000000-0000-4000-8000-000000000101', 'vlad@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000102', 'dmytro@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000103', 'viktoriia@hellonod.app', now() - interval '20 days', now()),
    ('10000000-0000-4000-8000-000000000111', 'attributed@example.invalid', now() - interval '2 days', now()),
    ('10000000-0000-4000-8000-000000000112', 'unknown@example.invalid', now() - interval '1 hour', now()),
    ('10000000-0000-4000-8000-000000000113', 'revoked@example.invalid', now() - interval '4 days', now()),
    ('10000000-0000-4000-8000-000000000121', 'immutable@example.invalid', now() - interval '1 day', now()),
    ('10000000-0000-4000-8000-000000000122', 'historical@example.invalid', now() - interval '10 days', now()),
    ('10000000-0000-4000-8000-000000000123', 'historical-later@example.invalid', now() - interval '10 days', now());

insert into public.acquisition_touches (
    id, visitor_id, session_id, occurred_at, event, page_path, page_group,
    referrer_host, utm_source, utm_medium, utm_campaign, consent_version
)
values
    ('20000000-0000-4000-8000-000000000111', '30000000-0000-4000-8000-000000000111', '40000000-0000-4000-8000-000000000111', now() - interval '3 days', 'page_view', '/pricing', 'pricing', 'google.com', 'google', 'cpc', 'founder-search', 'web-v1'),
    ('20000000-0000-4000-8000-000000000113', '30000000-0000-4000-8000-000000000113', '40000000-0000-4000-8000-000000000113', now() - interval '5 days', 'page_view', '/private', 'other', 'example.com', 'private-source', 'referral', 'must-disappear', 'web-v1'),
    ('20000000-0000-4000-8000-000000000121', '30000000-0000-4000-8000-000000000121', '40000000-0000-4000-8000-000000000121', now() - interval '2 days', 'page_view', '/first', 'other', 'first.example', 'first-source', 'referral', 'first-campaign', 'web-v1'),
    ('20000000-0000-4000-8000-000000000125', '30000000-0000-4000-8000-000000000125', '40000000-0000-4000-8000-000000000125', now() - interval '2 days', 'page_view', '/later', 'other', 'later.example', 'later-source', 'referral', 'later-campaign', 'web-v1'),
    ('20000000-0000-4000-8000-000000000122', '30000000-0000-4000-8000-000000000122', '40000000-0000-4000-8000-000000000122', now() - interval '11 days', 'page_view', '/historical', 'other', 'historical.example', 'historical-source', 'referral', 'historical-campaign', 'web-v1'),
    ('20000000-0000-4000-8000-000000000123', '30000000-0000-4000-8000-000000000123', '40000000-0000-4000-8000-000000000123', now() - interval '11 days', 'page_view', '/historical-later', 'other', 'kept.example', 'kept-source', 'referral', 'kept-campaign', 'web-v1');

insert into public.user_acquisition (
    user_id, claimed_visitor_id, first_touch_id, last_touch_id, coverage_status
)
values
    ('10000000-0000-4000-8000-000000000111', '30000000-0000-4000-8000-000000000111', '20000000-0000-4000-8000-000000000111', '20000000-0000-4000-8000-000000000111', 'attributed'),
    ('10000000-0000-4000-8000-000000000112', '30000000-0000-4000-8000-000000000112', null, null, 'no_eligible_touch'),
    ('10000000-0000-4000-8000-000000000113', '30000000-0000-4000-8000-000000000113', '20000000-0000-4000-8000-000000000113', '20000000-0000-4000-8000-000000000113', 'attributed');

select public.revoke_acquisition_consent('30000000-0000-4000-8000-000000000113');

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"authenticated"}';
do $$
begin
    if (select source from public.founder_recent_signups(30, 100) where email = 'attributed@example.invalid') <> 'google'
       or (select attribution_status from public.founder_recent_signups(30, 100) where email = 'revoked@example.invalid') <> 'consent_revoked'
       or (select source from public.founder_recent_signups(30, 100) where email = 'revoked@example.invalid') is not null then
        raise exception 'consent-safe dashboard attribution failed';
    end if;
    if (select email from public.founder_recent_signups(30, 1, 'attributed')) <> 'attributed@example.invalid' then
        raise exception 'recent-signup filter ran after limit';
    end if;
    if (select count(*) from public.founder_user_attribution(array['10000000-0000-4000-8000-000000000111'::uuid])) <> 1
       or exists (select 1 from public.founder_user_attribution('{}'::uuid[])) then
        raise exception 'bounded attribution contract failed';
    end if;
    begin perform public.founder_recent_signups(30, null); raise exception 'null limit succeeded'; exception when invalid_parameter_value then null; end;
    begin perform public.founder_recent_signups(null, 10); raise exception 'null days succeeded'; exception when invalid_parameter_value then null; end;
    begin perform public.founder_recent_signups(30, 10, 'invalid'); raise exception 'invalid filter succeeded'; exception when invalid_parameter_value then null; end;
    begin perform public.founder_user_attribution(null); raise exception 'null IDs succeeded'; exception when invalid_parameter_value then null; end;
    begin perform public.founder_user_attribution(array(select gen_random_uuid() from generate_series(1, 101))); raise exception 'oversized IDs succeeded'; exception when invalid_parameter_value then null; end;
end;
$$;
reset role;

insert into public.acquisition_auth_flows (relay_id, visitor_id, expires_at)
values
    ('60000000-0000-4000-8000-000000000121', '30000000-0000-4000-8000-000000000121', now() + interval '1 day'),
    ('60000000-0000-4000-8000-000000000125', '30000000-0000-4000-8000-000000000125', now() + interval '1 day'),
    ('60000000-0000-4000-8000-000000000126', '30000000-0000-4000-8000-000000000126', now() + interval '1 day');
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000121","email":"immutable@example.invalid","role":"authenticated"}';
do $$
begin
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000121');
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000125');
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000126');
end;
$$;
reset role;
do $$
begin
    if (select claimed_visitor_id from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') <> '30000000-0000-4000-8000-000000000121'
       or (select last_touch_id from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') <> '20000000-0000-4000-8000-000000000121' then
        raise exception 'later relay replaced first claim';
    end if;
end;
$$;
select public.revoke_acquisition_consent('30000000-0000-4000-8000-000000000121');
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000121","email":"immutable@example.invalid","role":"authenticated"}';
do $$
begin
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000125');
end;
$$;
reset role;
do $$
begin
    if (select consent_revoked_at from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') is null
       or (select last_touch_id from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') is not null then
        raise exception 'later relay restored revoked claim';
    end if;
end;
$$;

insert into public.user_acquisition (user_id, first_touch_id, last_touch_id, coverage_status, claimed_at)
values
    ('10000000-0000-4000-8000-000000000122', '20000000-0000-4000-8000-000000000122', '20000000-0000-4000-8000-000000000122', 'attributed', '2026-08-01 10:00:00+00'),
    ('10000000-0000-4000-8000-000000000123', '20000000-0000-4000-8000-000000000123', '20000000-0000-4000-8000-000000000123', 'attributed', '2026-08-01 11:00:00+00');
insert into public.acquisition_auth_flows (relay_id, visitor_id, expires_at, claimed_by, claimed_at)
values
    ('61000000-0000-4000-8000-000000000122', '30000000-0000-4000-8000-000000000122', now() + interval '1 day', '10000000-0000-4000-8000-000000000122', '2026-08-01 10:00:00+00'),
    ('61000000-0000-4000-8000-000000000123', '30000000-0000-4000-8000-000000000123', now() + interval '1 day', '10000000-0000-4000-8000-000000000123', '2026-08-01 11:00:00+00'),
    ('61000000-0000-4000-8000-000000000129', '30000000-0000-4000-8000-000000000129', now() + interval '1 day', '10000000-0000-4000-8000-000000000123', '2026-08-02 11:00:00+00');
insert into public.acquisition_consent_revocations (visitor_id, revoked_at)
values
    ('30000000-0000-4000-8000-000000000122', '2026-08-03 10:00:00+00'),
    ('30000000-0000-4000-8000-000000000129', '2026-08-03 11:00:00+00');
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"authenticated"}';
do $$
declare historical record;
begin
    select * into historical
      from public.founder_user_attribution(array['10000000-0000-4000-8000-000000000122'::uuid]);
    if historical.attribution_status <> 'unknown'
       or historical.source is not null
       or historical.medium is not null
       or historical.campaign_name is not null
       or historical.referrer_host is not null
       or historical.landing_path is not null then
        raise exception 'orphan legacy acquisition exposed inferred attribution: %', historical;
    end if;
end;
$$;
reset role;

insert into private.founder_mcp_client_access (user_id, client_id, resource_uri)
values
    ('10000000-0000-4000-8000-000000000101', 'dcr-vlad', 'https://founder.example/mcp'),
    ('10000000-0000-4000-8000-000000000102', 'dcr-dmytro', 'https://founder.example/mcp');
update private.connector_oauth_config set founder_mcp_enabled = true where singleton;

do $$
declare
    vlad jsonb;
    wrong_pair jsonb;
    meeting jsonb;
begin
    vlad := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000101', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000101', 'client_id', 'dcr-vlad', 'email', 'changed@example.invalid'))) -> 'claims';
    wrong_pair := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000102', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000102', 'client_id', 'dcr-vlad'))) -> 'claims';
    meeting := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000111', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000111', 'client_id', 'meeting-dcr'))) -> 'claims';
    if not (vlad -> 'nod_permissions' ? 'founder_analytics:read')
       or wrong_pair -> 'nod_permissions' ? 'founder_analytics:read'
       or not (meeting -> 'nod_permissions' ? 'meetings:read') then
        raise exception 'UUID/client token mapping or meeting regression failed';
    end if;
end;
$$;

do $$
begin
    if has_table_privilege('mcp_connector', 'public.user_acquisition', 'SELECT')
       or not has_function_privilege('mcp_connector', 'public.founder_mcp_gateway(text,jsonb)', 'EXECUTE')
       or has_function_privilege('mcp_connector', 'public.founder_mcp_report(text,integer,text,integer)', 'EXECUTE')
       or has_function_privilege('mcp_connector', 'public.founder_mcp_recent_signups(integer,integer,text,boolean)', 'EXECUTE')
       or has_function_privilege('mcp_connector', 'public.founder_mcp_find_user(text)', 'EXECUTE') then
        raise exception 'gateway-only grants failed';
    end if;
end;
$$;

set local role mcp_connector;
do $$
declare claim jsonb;
begin
    foreach claim in array array[
        '{"sub":"10000000-0000-4000-8000-000000000101","role":"mcp_connector","client_id":"dcr-vlad","nod_permissions":["founder_analytics:read"]}'::jsonb,
        '{"sub":"10000000-0000-4000-8000-000000000101","role":"mcp_connector","client_id":"dcr-vlad","aud":{},"nod_permissions":["founder_analytics:read"]}'::jsonb,
        '{"sub":"10000000-0000-4000-8000-000000000101","role":"mcp_connector","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":{"founder_analytics:read":true}}'::jsonb,
        '{"sub":"10000000-0000-4000-8000-000000000101","role":"authenticated","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}'::jsonb
    ] loop
        perform set_config('request.jwt.claims', claim::text, true);
        begin perform public.founder_mcp_gateway('find_user', '{"query":"abc"}'); raise exception 'invalid claim succeeded'; exception when insufficient_privilege then null; end;
    end loop;
end;
$$;

set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"mcp_connector","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}';
do $$
declare
    recent jsonb;
    report jsonb;
begin
    recent := public.founder_mcp_gateway('list_recent_signups', '{"days":30,"limit":100,"include_identity":false}');
    report := public.founder_mcp_gateway('get_founder_report', '{"report":"overview"}');
    if recent ->> 'truncated' <> 'false'
       or recent::text like '%attributed@example.invalid%'
       or report -> 'result' ->> 'window_semantics' <> 'all_time'
       or public.founder_mcp_gateway('find_user', '{"query":"a"}') ->> 'error' <> 'invalid_arguments'
       or public.founder_mcp_gateway('get_founder_report', '{"report":"overview","days":7}') ->> 'error' <> 'invalid_arguments'
       or public.founder_mcp_gateway('list_recent_signups', '{"limit":null}') ->> 'error' <> 'invalid_arguments' then
        raise exception 'gateway envelope, bounds, or argument validation failed';
    end if;
end;
$$;
reset role;

delete from private.founder_mcp_rate_limits;
delete from private.founder_mcp_audit_events;
set local role mcp_connector;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"mcp_connector","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}';
do $$
declare index integer; result jsonb;
begin
    for index in 1..35 loop result := public.founder_mcp_gateway('find_user', null); end loop;
    if result ->> 'error' <> 'rate_limited' then raise exception 'rate limit failed'; end if;
end;
$$;
reset role;
do $$
begin
    if (select count(*) from private.founder_mcp_audit_events where status = 'rate_limited') <> 1
       or (select count(*) from private.founder_mcp_audit_events) > 31
       or exists (
           select 1 from information_schema.columns
            where table_schema = 'private' and table_name = 'founder_mcp_audit_events'
              and column_name in ('query', 'search_text', 'request', 'response', 'result')
       ) then
        raise exception 'audit rate/content bounds failed';
    end if;
end;
$$;

update private.connector_oauth_config set founder_mcp_enabled = false where singleton;
set local role mcp_connector;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"mcp_connector","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}';
do $$
begin
    perform public.founder_mcp_gateway('find_user', '{"query":"abc"}');
    raise exception 'database kill switch failed';
exception when insufficient_privilege then null;
end;
$$;

rollback;
