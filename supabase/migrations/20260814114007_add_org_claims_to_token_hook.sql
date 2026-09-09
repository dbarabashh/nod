-- A token can say which organizations its holder belongs to.
--
-- This edits the one function every sign-in already runs, which makes it the
-- only change in this line of work whose blast radius is everybody. Three things
-- follow from that, and they are the whole design:
--
--   1. The connector branch is preserved exactly. Tokens carrying `client_id`
--      take the same path, produce the same claims, and never see an org — an
--      MCP connector is scoped to `meetings:read` and nothing here widens it.
--   2. The new work runs inside its own exception handler that returns the
--      untouched event. Supabase does not document what happens when this hook
--      raises, so the safe assumption is that it costs a sign-in; the handler
--      makes a bug here degrade to "no org claims" instead of "no login".
--   3. A holder with no memberships gets the event back unchanged, byte for
--      byte. Every account today has no memberships, so every token issued today
--      is identical before and after this migration.
--
-- Claims are named `nod_orgs` / `nod_teams`, following the `nod_permissions`
-- claim the connector branch already sets, rather than written into
-- `app_metadata` — that object belongs to GoTrue and carries the identity
-- provider list, and reaching into it to add a key risks the one thing this
-- function must never do.
--
-- To roll this back, restore the previous function body — one `create or
-- replace`, kept whole in `20260806120000_connector_oauth.sql`. Do *not* reach
-- for the `[auth.hook.custom_access_token]` switch in `supabase/config.toml`:
-- the hook is shared, and disabling it would take the connector branch down with
-- this one, leaving MCP tokens without their audience, role and scope. The
-- switch is the right lever only when the hook itself is the problem.

-- Reads membership on behalf of a hook that runs as `supabase_auth_admin`, a
-- role with no rights on these tables and no reason to be given any. SECURITY
-- DEFINER keeps the RLS bypass inside one function whose only caller is the
-- hook, instead of granting the auth role standing access to product data.
create function public._org_claims_for(p_user uuid)
    returns jsonb
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select case
        when o.orgs is null then null
        else jsonb_build_object('orgs', o.orgs, 'teams', coalesce(t.teams, '[]'::jsonb))
    end
    from (
        select jsonb_agg(jsonb_build_object('id', org_id, 'role', role) order by org_id) as orgs
        from public.org_members
        where user_id = p_user and status = 'active'
    ) o
    left join lateral (
        select jsonb_agg(tm.team_id order by tm.team_id) as teams
        from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
        where tm.user_id = p_user
    ) t on true;
$$;

revoke all on function public._org_claims_for(uuid) from public, anon, authenticated;
grant execute on function public._org_claims_for(uuid) to supabase_auth_admin;

create or replace function public.custom_access_token_hook(event jsonb)
    returns jsonb
    language plpgsql
    stable
as $function$
declare
    claims jsonb := event -> 'claims';
    resource_uri text;
    org_claims jsonb;
begin
    -- Unchanged from `20260806120000_connector_oauth.sql`. A connector token is
    -- audience-bound and read-only; membership has no meaning for it.
    if claims ->> 'client_id' is not null then
        select config.resource_uri
          into strict resource_uri
          from private.connector_oauth_config as config
         where config.singleton;

        claims := jsonb_set(claims, '{aud}', to_jsonb(resource_uri), true);
        claims := jsonb_set(claims, '{role}', '"mcp_connector"'::jsonb, true);
        claims := jsonb_set(claims, '{nod_permissions}', '["meetings:read"]'::jsonb, true);

        return jsonb_build_object('claims', claims);
    end if;

    begin
        org_claims := public._org_claims_for((event ->> 'user_id')::uuid);
    exception when others then
        return event;
    end;

    if org_claims is null then
        return event;
    end if;

    claims := jsonb_set(claims, '{nod_orgs}', org_claims -> 'orgs', true);
    claims := jsonb_set(claims, '{nod_teams}', org_claims -> 'teams', true);

    return jsonb_build_object('claims', claims);
end;
$function$;

revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
