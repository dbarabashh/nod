-- One hook, both kinds of token.
--
-- `20260814114007` taught the hook to name a holder's organizations;
-- `20260827081104` taught it to tell a founder connector from a meeting one.
-- They were written on separate branches against separate parents, and each is
-- a whole `create or replace` of the same function, so nothing conflicted and
-- the later timestamp simply won: merging main here left the founder branch
-- standing and dropped `nod_orgs` / `nod_teams` from every ordinary sign-in.
--
-- This states the function once, with both halves, so the next reader is not
-- reconstructing it from two migrations that never met.

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
    org_claims jsonb;
begin
    if claims ->> 'client_id' is null then
        -- Supabase does not document what an raising hook costs, so a bug in
        -- membership degrades to "no org claims" rather than "no login".
        begin
            org_claims := public._org_claims_for(subject_id);
        exception when others then
            return event;
        end;

        if org_claims is null then
            return event;
        end if;

        claims := jsonb_set(claims, '{nod_orgs}', org_claims -> 'orgs', true);
        claims := jsonb_set(claims, '{nod_teams}', org_claims -> 'teams', true);

        return jsonb_build_object('claims', claims);
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

revoke all on function public.custom_access_token_hook(jsonb) from public, anon, authenticated, mcp_connector;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
