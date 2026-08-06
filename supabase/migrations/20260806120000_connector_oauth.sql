create schema if not exists private;

create table private.connector_oauth_config (
    singleton boolean primary key default true check (singleton),
    resource_uri text not null check (resource_uri ~ '^https://[^[:space:]]+/mcp$')
);

insert into private.connector_oauth_config (resource_uri)
values ('https://hellonod.app/mcp');

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'mcp_connector') then
        create role mcp_connector nologin noinherit;
    end if;
end;
$$;

grant mcp_connector to authenticator;
revoke all on schema public from mcp_connector;
revoke all on all tables in schema public from mcp_connector;
revoke all on all sequences in schema public from mcp_connector;
revoke all on all functions in schema public from mcp_connector;
alter default privileges in schema public revoke all on tables from mcp_connector;
alter default privileges in schema public revoke all on sequences from mcp_connector;
alter default privileges in schema public revoke all on functions from mcp_connector;

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
    claims jsonb := event -> 'claims';
    resource_uri text;
begin
    if claims ->> 'client_id' is null then
        return event;
    end if;

    select config.resource_uri
      into strict resource_uri
      from private.connector_oauth_config as config
     where config.singleton;

    claims := jsonb_set(claims, '{aud}', to_jsonb(resource_uri), true);
    claims := jsonb_set(claims, '{role}', '"mcp_connector"'::jsonb, true);
    claims := jsonb_set(claims, '{nod_permissions}', '["meetings:read"]'::jsonb, true);

    return jsonb_build_object('claims', claims);
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant usage on schema private to supabase_auth_admin;
grant select on private.connector_oauth_config to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated, mcp_connector;

comment on table private.connector_oauth_config is
'Environment-specific OAuth resource binding. Update the singleton on each preview branch before enabling OAuth.';
