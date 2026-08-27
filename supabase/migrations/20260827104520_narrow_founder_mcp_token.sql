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
