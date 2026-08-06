alter table public.app_config
    add column official_connectors_enabled boolean not null default false,
    add column chatgpt_connector_url text,
    add column claude_connector_url text,
    add column legacy_pat_sunset_at timestamptz,
    add constraint app_config_chatgpt_connector_url_https
        check (chatgpt_connector_url is null or chatgpt_connector_url ~ '^https://'),
    add constraint app_config_claude_connector_url_https
        check (claude_connector_url is null or claude_connector_url ~ '^https://');

create or replace function public.create_connection(
    p_name text,
    p_client text,
    p_token_hash text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id uuid;
    v_official_connectors_enabled boolean;
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;

    select official_connectors_enabled
      into v_official_connectors_enabled
      from public.app_config
     where singleton;

    if coalesce(v_official_connectors_enabled, false) then
        raise exception 'personal connector tokens are no longer issued';
    end if;

    if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'invalid token hash';
    end if;

    insert into public.connections (user_id, token_hash, name, client)
    values (
        auth.uid(),
        p_token_hash,
        coalesce(nullif(btrim(p_name), ''), 'Connection'),
        coalesce(nullif(btrim(p_client), ''), 'other')
    )
    returning id into v_id;

    return v_id;
end;
$$;
