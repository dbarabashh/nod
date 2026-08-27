-- The organization integration policy, as the server enforces it.
--
-- These are the cases everything else bets on. `resolveConnection` refuses on
-- the strength of them, so does the calendar sweep, so does approving a
-- proposal, and so does the desktop client — which asks rather than derives.
-- A rule that drifts here does not fail loudly: it draws a tool as available
-- and then refuses it, or worse, permits one a company forbade.

begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('50000000-0000-4000-8000-000000000001', 'policy-member@example.invalid', now(), now()),
    ('50000000-0000-4000-8000-000000000002', 'policy-leaver@example.invalid', now(), now()),
    ('50000000-0000-4000-8000-000000000003', 'policy-solo@example.invalid', now(), now());

insert into public.organizations (id, name, slug, created_by)
values
    ('51000000-0000-4000-8000-000000000001', 'Forbids Slack', 'policy-forbids',
     '50000000-0000-4000-8000-000000000001'),
    ('51000000-0000-4000-8000-000000000002', 'Permits Everything', 'policy-permits',
     '50000000-0000-4000-8000-000000000001');

-- The member belongs to both: one forbids Slack, the other has said nothing.
insert into public.org_members (org_id, user_id, role, status)
values
    ('51000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001', 'member', 'active'),
    ('51000000-0000-4000-8000-000000000002', '50000000-0000-4000-8000-000000000001', 'member', 'active'),
    ('51000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000002', 'member', 'deprovisioned');

insert into public.org_integration_policies (org_id, provider, is_allowed)
values
    ('51000000-0000-4000-8000-000000000001', 'slack', false),
    ('51000000-0000-4000-8000-000000000001', 'linear', true);

do $$
begin
    if public.user_may_use_provider('50000000-0000-4000-8000-000000000001', 'slack') then
        raise exception 'a forbidding organization did not bar its member';
    end if;

    -- The whole reason the rule is written as "no organization forbids" rather
    -- than "some organization permits": a second membership must not be a way
    -- around the first one's answer.
    if not public.user_may_use_provider('50000000-0000-4000-8000-000000000001', 'linear') then
        raise exception 'an explicitly allowed provider was barred';
    end if;

    -- Absence means allowed. Every organization that predates the setting has
    -- no row, and default-deny would switch off integrations nobody asked to
    -- have switched off.
    if not public.user_may_use_provider('50000000-0000-4000-8000-000000000001', 'github') then
        raise exception 'a provider with no policy row was barred';
    end if;

    -- Somebody who left does not carry the company's policy with them.
    if not public.user_may_use_provider('50000000-0000-4000-8000-000000000002', 'slack') then
        raise exception 'a deprovisioned membership barred a provider';
    end if;

    -- A personal account is governed by nobody.
    if not public.user_may_use_provider('50000000-0000-4000-8000-000000000003', 'slack') then
        raise exception 'an account in no organization was barred';
    end if;
end;
$$;

-- The sweep's shape has to answer identically to the door's, for the same
-- people. `calendar-sync` skips whoever this names and reads whoever it does
-- not.
do $$
declare
    v_barred uuid[];
begin
    select coalesce(array_agg(user_id order by user_id), '{}')
      into v_barred
      from public.users_barred_from_provider(
          array['50000000-0000-4000-8000-000000000001'::uuid,
                '50000000-0000-4000-8000-000000000002'::uuid,
                '50000000-0000-4000-8000-000000000003'::uuid],
          'slack');

    if v_barred <> array['50000000-0000-4000-8000-000000000001'::uuid] then
        raise exception 'sweep filter named the wrong people: %', v_barred;
    end if;

    if exists (
        select 1 from public.users_barred_from_provider(
            array['50000000-0000-4000-8000-000000000001'::uuid], 'github')
    ) then
        raise exception 'sweep filter barred a provider with no policy row';
    end if;
end;
$$;

-- One membership, two forbidding organizations: the row is named once, or the
-- sweep's `Set` hides a duplicate the door would have counted twice.
insert into public.org_integration_policies (org_id, provider, is_allowed)
values ('51000000-0000-4000-8000-000000000002', 'slack', false);

do $$
begin
    if (select count(*) from public.users_barred_from_provider(
            array['50000000-0000-4000-8000-000000000001'::uuid], 'slack')) <> 1 then
        raise exception 'two forbidding organizations named the same person twice';
    end if;
end;
$$;

-- The client renders the same rule, through the one shape that may be granted
-- to a signed-in account. Asked as the member, so `auth.uid()` is what the
-- function sees.
set local role authenticated;
set local request.jwt.claims = '{"sub":"50000000-0000-4000-8000-000000000001"}';

do $$
declare
    v_blocked text[];
begin
    select coalesce(array_agg(provider order by provider), '{}')
      into v_blocked
      from public.my_blocked_providers();

    if v_blocked <> array['slack'] then
        raise exception 'the client-facing rule disagrees with the server: %', v_blocked;
    end if;
end;
$$;

reset role;
reset request.jwt.claims;

-- The two user-id-taking functions may not be reachable by a signed-in account:
-- answering for an arbitrary one would report on other people's employers.
-- `my_blocked_providers` takes no argument and so can only answer about its
-- caller, which is why it is the one the client gets.
do $$
begin
    if has_function_privilege('authenticated', 'public.user_may_use_provider(uuid, text)', 'execute')
       or has_function_privilege('anon', 'public.user_may_use_provider(uuid, text)', 'execute')
       or has_function_privilege('authenticated', 'public.users_barred_from_provider(uuid[], text)', 'execute')
       or has_function_privilege('anon', 'public.users_barred_from_provider(uuid[], text)', 'execute')
       or has_function_privilege('authenticated', 'public.org_allows_provider(uuid, text)', 'execute')
    then
        raise exception 'a policy function that takes an org or user id is callable by a client';
    end if;
    if not has_function_privilege('service_role', 'public.user_may_use_provider(uuid, text)', 'execute') then
        raise exception 'the edge functions cannot call the policy check';
    end if;
    if not has_function_privilege('authenticated', 'public.my_blocked_providers()', 'execute') then
        raise exception 'the client cannot read its own blocked providers';
    end if;
end;
$$;

rollback;
