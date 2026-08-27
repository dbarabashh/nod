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
    ('10000000-0000-4000-8000-000000000123', 'historical-later@example.invalid', now() - interval '10 days', now()),
    ('10000000-0000-4000-8000-000000000124', 'historical-unknown@example.invalid', now() - interval '10 days', now());

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
       or (select source from public.founder_recent_signups(30, 100) where email = 'revoked@example.invalid') is not null
       or (select attribution_status from public.founder_recent_signups(30, 100) where email = 'unknown@example.invalid') <> 'no_eligible_touch'
       or exists (
           select 1
             from public.founder_recent_signups(30, 100)
            where email in ('vlad@hellonod.app', 'dmytro@hellonod.app', 'viktoriia@hellonod.app')
       ) then
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

set local role anon;
set local request.jwt.claims = '{}';
do $$
begin
    perform public.founder_recent_signups(30, 10);
    raise exception 'anonymous dashboard RPC succeeded';
exception when insufficient_privilege then null;
end;
$$;
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000111","email":"attributed@example.invalid","role":"authenticated"}';
do $$
begin
    perform public.founder_recent_signups(30, 10);
    raise exception 'non-founder dashboard RPC succeeded';
exception when insufficient_privilege then null;
end;
$$;
reset role;

insert into public.acquisition_auth_flows (relay_id, visitor_id, expires_at)
values
    ('60000000-0000-4000-8000-000000000121', '30000000-0000-4000-8000-000000000121', now() + interval '1 day'),
    ('60000000-0000-4000-8000-000000000125', '30000000-0000-4000-8000-000000000125', now() + interval '1 day'),
    ('60000000-0000-4000-8000-000000000126', '30000000-0000-4000-8000-000000000126', now() + interval '1 day'),
    ('60000000-0000-4000-8000-000000000127', '30000000-0000-4000-8000-000000000127', now() + interval '1 day');
select public.revoke_acquisition_consent('30000000-0000-4000-8000-000000000127');
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000121","email":"immutable@example.invalid","role":"authenticated"}';
do $$
begin
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000121');
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000125');
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000126');
    perform public.claim_acquisition_flow('60000000-0000-4000-8000-000000000127');
end;
$$;
reset role;
update public.acquisition_auth_flows
   set claimed_at = '2026-08-01 09:00:00+00'
 where relay_id = '60000000-0000-4000-8000-000000000121';
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000121","email":"immutable@example.invalid","role":"authenticated"}';
select public.claim_acquisition_flow('60000000-0000-4000-8000-000000000121');
reset role;
do $$
begin
    if (select claimed_visitor_id from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') <> '30000000-0000-4000-8000-000000000121'
       or (select last_touch_id from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') <> '20000000-0000-4000-8000-000000000121'
       or (select consent_revoked_at from public.user_acquisition where user_id = '10000000-0000-4000-8000-000000000121') is not null
       or (select claimed_at from public.acquisition_auth_flows where relay_id = '60000000-0000-4000-8000-000000000121') <> '2026-08-01 09:00:00+00' then
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
    ('10000000-0000-4000-8000-000000000123', '20000000-0000-4000-8000-000000000123', '20000000-0000-4000-8000-000000000123', 'attributed', '2026-08-01 11:00:00+00'),
    ('10000000-0000-4000-8000-000000000124', null, null, 'no_eligible_touch', '2026-08-01 12:00:00+00');
insert into public.acquisition_auth_flows (relay_id, visitor_id, expires_at, claimed_by, claimed_at)
values
    ('61000000-0000-4000-8000-000000000122', '30000000-0000-4000-8000-000000000122', now() + interval '1 day', '10000000-0000-4000-8000-000000000122', '2026-08-01 10:00:00+00'),
    ('61000000-0000-4000-8000-000000000123', '30000000-0000-4000-8000-000000000123', now() + interval '1 day', '10000000-0000-4000-8000-000000000123', '2026-08-01 11:00:00+00'),
    ('61000000-0000-4000-8000-000000000129', '30000000-0000-4000-8000-000000000129', now() + interval '1 day', '10000000-0000-4000-8000-000000000123', '2026-08-02 11:00:00+00');
insert into public.acquisition_consent_revocations (visitor_id, revoked_at)
values
    ('30000000-0000-4000-8000-000000000122', '2026-08-03 10:00:00+00'),
    ('30000000-0000-4000-8000-000000000129', '2026-08-03 11:00:00+00');
update public.user_acquisition
   set first_touch_id = null,
       last_touch_id = null,
       coverage_status = 'no_eligible_touch'
 where user_id = '10000000-0000-4000-8000-000000000122';
delete from public.acquisition_touches
 where visitor_id = '30000000-0000-4000-8000-000000000122';
select private.backfill_user_acquisition_consent_revocations();
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"authenticated"}';
do $$
declare
    revoked record;
    preserved record;
    unknown record;
begin
    select * into revoked
      from public.founder_user_attribution(array['10000000-0000-4000-8000-000000000122'::uuid]);
    select * into preserved
      from public.founder_user_attribution(array['10000000-0000-4000-8000-000000000123'::uuid]);
    select * into unknown
      from public.founder_user_attribution(array['10000000-0000-4000-8000-000000000124'::uuid]);
    if revoked.attribution_status <> 'consent_revoked'
       or revoked.source is not null
       or revoked.medium is not null
       or revoked.campaign_name is not null
       or revoked.referrer_host is not null
       or revoked.landing_path is not null then
        raise exception 'exact historical revocation backfill failed: %', revoked;
    end if;
    if preserved.attribution_status <> 'attributed'
       or preserved.source <> 'kept-source' then
        raise exception 'later revoked relay relabeled the historical first claim: %', preserved;
    end if;
    if unknown.attribution_status <> 'unknown'
       or unknown.source is not null
       or unknown.medium is not null
       or unknown.campaign_name is not null
       or unknown.referrer_host is not null
       or unknown.landing_path is not null then
        raise exception 'orphan legacy acquisition exposed inferred attribution: %', unknown;
    end if;
end;
$$;
reset role;

insert into public.meetings (
    id, user_id, started_at, ended_at, created_at, summary, language
)
values
    ('70000000-0000-4000-8000-000000000112', '10000000-0000-4000-8000-000000000112', now() - interval '40 minutes', now() - interval '40 minutes', now() - interval '40 minutes', 'placeholder', 'en'),
    ('70000000-0000-4000-8000-000000000113', '10000000-0000-4000-8000-000000000112', now() - interval '30 minutes', now() - interval '30 minutes', now() - interval '30 minutes', 'placeholder', 'en');

insert into private.founder_mcp_client_access (user_id, client_id, resource_uri)
values
    ('10000000-0000-4000-8000-000000000101', 'dcr-vlad', 'https://founder.example/mcp'),
    ('10000000-0000-4000-8000-000000000102', 'dcr-dmytro', 'https://founder.example/mcp');
update private.connector_oauth_config set founder_mcp_enabled = true where singleton;

-- `founder_mcp_report` delegates to `founder_overview`, `founder_metrics` and
-- `founder_acquisition`, each of which asserts `_assert_founder()` against the
-- email allowlist. A binding whose user is not also on that list therefore
-- issues a working token whose reports fail, and the gateway's catch-all
-- reports that as `invalid_arguments`.
do $$
begin
    if exists (
        select 1
          from private.founder_mcp_client_access as access
          join auth.users as account on account.id = access.user_id
         where lower(account.email) <> all(public._founder_emails())
    ) then
        raise exception 'founder MCP binding is not on the founder email allowlist';
    end if;
end;
$$;

do $$
declare
    vlad jsonb;
    dmytro jsonb;
    wrong_pair jsonb;
    viktoriia jsonb;
    meeting jsonb;
    plain_login jsonb;
begin
    vlad := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000101', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000101', 'client_id', 'dcr-vlad', 'email', 'changed@example.invalid'))) -> 'claims';
    dmytro := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000102', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000102', 'client_id', 'dcr-dmytro'))) -> 'claims';
    wrong_pair := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000102', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000102', 'client_id', 'dcr-vlad'))) -> 'claims';
    viktoriia := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000103', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000103', 'client_id', 'dcr-dmytro'))) -> 'claims';
    meeting := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000111', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000111', 'client_id', 'meeting-dcr'))) -> 'claims';
    plain_login := public.custom_access_token_hook(jsonb_build_object('user_id', '10000000-0000-4000-8000-000000000111', 'claims', jsonb_build_object('sub', '10000000-0000-4000-8000-000000000111')));
    if not (vlad -> 'nod_permissions' ? 'founder_analytics:read')
       or not (dmytro -> 'nod_permissions' ? 'founder_analytics:read')
       or wrong_pair -> 'nod_permissions' ? 'founder_analytics:read'
       or viktoriia -> 'nod_permissions' ? 'founder_analytics:read'
       or not (meeting -> 'nod_permissions' ? 'meetings:read')
       or plain_login -> 'claims' ? 'role'
       or plain_login -> 'claims' ? 'nod_permissions' then
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
       or has_function_privilege('mcp_connector', 'public.founder_mcp_find_user(text)', 'EXECUTE')
       or has_function_privilege('mcp_connector', 'private.purge_founder_mcp_audit_events()', 'EXECUTE') then
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
        '{"sub":"10000000-0000-4000-8000-000000000101","role":"authenticated","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}'::jsonb,
        '{"sub":"10000000-0000-4000-8000-000000000103","role":"mcp_connector","client_id":"dcr-dmytro","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}'::jsonb
    ] loop
        perform set_config('request.jwt.claims', claim::text, true);
        begin perform public.founder_mcp_gateway('find_user', '{"query":"abc"}'); raise exception 'invalid claim succeeded'; exception when insufficient_privilege then null; end;
    end loop;
end;
$$;

set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000102","email":"dmytro@hellonod.app","role":"mcp_connector","client_id":"dcr-dmytro","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}';
do $$
begin
    if public.founder_mcp_gateway('list_recent_signups', '{"days":30,"limit":1}') ? 'error' then
        raise exception 'Dmytro exact MCP binding was denied';
    end if;
end;
$$;

set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000101","email":"vlad@hellonod.app","role":"mcp_connector","client_id":"dcr-vlad","aud":"https://founder.example/mcp","nod_permissions":["founder_analytics:read"]}';
do $$
declare
    recent jsonb;
    report jsonb;
    acquisition jsonb;
    activation jsonb;
    found_user jsonb;
begin
    recent := public.founder_mcp_gateway('list_recent_signups', '{"days":30,"limit":100,"include_identity":false}');
    report := public.founder_mcp_gateway('get_founder_report', '{"report":"overview"}');
    acquisition := public.founder_mcp_gateway('get_founder_report', '{"report":"acquisition","days":30}');
    activation := public.founder_mcp_gateway('get_founder_report', '{"report":"activation","days":30}');
    found_user := public.founder_mcp_gateway('find_user', '{"query":"unknown@example.invalid"}');
    if recent ->> 'truncated' <> 'false'
       or recent::text like '%attributed@example.invalid%'
       or report -> 'result' ->> 'window_semantics' <> 'section_specific'
       or not (report -> 'result' -> 'overview' ? 'weekly_retained_pct')
       or report -> 'result' -> 'overview' ? 'activation_rate'
       or report -> 'result' -> 'section_windows' -> 'totals' ->> 'semantics' <> 'field_defined'
       or (acquisition -> 'result' -> 'summary' ->> 'users_with_meeting')::integer <> 0
       or (acquisition -> 'result' -> 'summary' ->> 'signup_to_meeting_pct')::numeric <> 0
       or activation -> 'result' ->> 'window_semantics' <> 'section_specific'
       or activation -> 'result' ? 'summary'
       or (activation -> 'result' -> 'onboarding' -> 'activation' ->> 'second_meeting_within_three_days')::integer <> 0
       or found_user -> 'result' -> 'matches' -> 0 ->> 'lifecycle_state' <> 'new'
       or (found_user -> 'result' -> 'matches' -> 0 ->> 'meetings_count')::integer <> 0
       or (found_user -> 'result' -> 'matches' -> 0 ->> 'activated')::boolean
       or found_user -> 'result' -> 'matches' -> 0 ->> 'first_meeting_at' is not null
       or public.founder_mcp_gateway('find_user', '{"query":"a"}') ->> 'error' <> 'invalid_arguments'
       or public.founder_mcp_gateway('find_user', jsonb_build_object('query', repeat('a', 121))) ->> 'error' <> 'invalid_arguments'
       or public.founder_mcp_gateway('get_founder_report', '{"report":"overview","days":7}') ->> 'error' <> 'invalid_arguments'
       or public.founder_mcp_gateway('list_recent_signups', '{"limit":null,"include_identity":true}') ->> 'error' <> 'invalid_arguments' then
        raise exception 'gateway envelope, bounds, or argument validation failed';
    end if;
end;
$$;
reset role;

do $$
begin
    if not exists (
        select 1
          from private.founder_mcp_audit_events
         where tool = 'find_user'
           and status = 'error'
           and identity_query_length = 1
    ) or not exists (
        select 1
          from private.founder_mcp_audit_events
         where tool = 'find_user'
           and status = 'error'
           and identity_query_length = 120
    ) or not exists (
        select 1
          from private.founder_mcp_audit_events
         where tool = 'list_recent_signups'
           and status = 'error'
           and include_identity
    ) then
        raise exception 'rejected-call audit metadata was discarded';
    end if;
end;
$$;

insert into private.founder_mcp_audit_events (
    occurred_at, actor_id, client_id, tool, status, returned_row_count
)
values (
    now() - interval '91 days',
    '10000000-0000-4000-8000-000000000101',
    'dcr-vlad',
    'unknown',
    'error',
    0
);
select private.purge_founder_mcp_audit_events();
do $$
begin
    if exists (
        select 1
          from private.founder_mcp_audit_events
         where occurred_at < now() - interval '90 days'
    ) then
        raise exception 'scheduled audit retention helper did not prune old rows';
    end if;
end;
$$;

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
