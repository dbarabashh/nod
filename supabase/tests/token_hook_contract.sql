-- The hook runs on every token this product issues, and two branches of work
-- have now rewritten it whole. Neither rewrite conflicted with the other in
-- git, so the only thing that can hold both halves down is a test that fails
-- when one of them goes missing.

begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('50000000-0000-4000-8000-000000000001', 'member@example.invalid', now(), now()),
    ('50000000-0000-4000-8000-000000000002', 'loner@example.invalid', now(), now());

insert into public.organizations (id, name, slug, created_by)
values ('51000000-0000-4000-8000-000000000001', 'Contract Org', 'contract-org',
        '50000000-0000-4000-8000-000000000001');

insert into public.org_members (org_id, user_id, role, status)
values ('51000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001',
        'admin', 'active');

insert into public.teams (id, org_id, name, created_by)
values ('52000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001',
        'Contract Team', '50000000-0000-4000-8000-000000000001');

insert into public.team_members (team_id, user_id, role)
values ('52000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001', 'member');

do $$
declare
    member jsonb;
    loner jsonb;
    connector jsonb;
begin
    member := public.custom_access_token_hook(jsonb_build_object(
        'user_id', '50000000-0000-4000-8000-000000000001',
        'claims', jsonb_build_object('sub', '50000000-0000-4000-8000-000000000001'))) -> 'claims';
    loner := public.custom_access_token_hook(jsonb_build_object(
        'user_id', '50000000-0000-4000-8000-000000000002',
        'claims', jsonb_build_object('sub', '50000000-0000-4000-8000-000000000002')));
    connector := public.custom_access_token_hook(jsonb_build_object(
        'user_id', '50000000-0000-4000-8000-000000000001',
        'claims', jsonb_build_object(
            'sub', '50000000-0000-4000-8000-000000000001',
            'client_id', 'meeting-dcr'))) -> 'claims';

    -- Every check coalesces: a missing claim makes the operator return NULL,
    -- and `if NULL then` is not a failure, so an unguarded assertion passes
    -- precisely when the claim it guards has gone.
    if not coalesce(member -> 'nod_orgs' @> '[{"id": "51000000-0000-4000-8000-000000000001", "role": "admin"}]'::jsonb, false)
       or not coalesce(member -> 'nod_teams' ? '52000000-0000-4000-8000-000000000001', false) then
        raise exception 'a sign-in lost its organization claims';
    end if;

    if coalesce(member ? 'role', false) or coalesce(member ? 'nod_permissions', false) then
        raise exception 'a sign-in was given connector claims';
    end if;

    if coalesce(loner -> 'claims' ? 'nod_orgs', false)
       or coalesce(loner -> 'claims' ? 'role', false) then
        raise exception 'a member-less sign-in was not returned untouched';
    end if;

    -- A connector token is audience-bound and read-only; membership has no
    -- meaning for it and must never widen what it can reach.
    if not coalesce(connector -> 'nod_permissions' ? 'meetings:read', false)
       or coalesce(connector ->> 'role', '') <> 'mcp_connector'
       or coalesce(connector ? 'nod_orgs', false)
       or coalesce(connector ? 'nod_teams', false) then
        raise exception 'a connector token lost its scope or gained organizations';
    end if;
end;
$$;

rollback;
