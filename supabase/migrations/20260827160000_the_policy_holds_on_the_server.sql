-- `org_integration_policies` becomes a control instead of a hint.
--
-- The table, the admin pane and `org_allows_provider` shipped together, and
-- between them they gated exactly one thing: approving a proposal. Every other
-- way work reaches a third party — the chat's tool calls through
-- `integration-action`, a roster import through `directory-sync`, the scheduled
-- calendar read — asked only whether the person had connected the product. So
-- an organization that switched Slack off got a client that stopped drawing the
-- button and a server that would still post to Slack for anyone who asked it
-- to. `34. External Action Security` requires the check at the action, and the
-- action is where it was missing.
--
-- Two shapes of the same question, because the callers genuinely differ: a door
-- has one person in front of it, and the calendar sweep has two hundred. One
-- rule, defined once, so the two can never answer differently.
--
-- Membership is `status = 'active'`, matching `is_org_member` exactly rather
-- than approximately. The client derives the same answer by reading
-- `org_integration_policies` under that policy's own `using` clause, and a
-- server that disagreed with it would draw a tool as available and then refuse
-- it — the failure the client-side check existed to prevent.
--
-- Any organization, not the current one. Somebody can belong to two, the
-- proposal path is the only caller that ever knew which one a piece of work
-- was for, and a rule that let a second membership relax the first would be a
-- way around the control rather than an expression of it. A forbidding
-- organization forbids.
--
-- Absence still means allowed. Nothing here introduces a default, and an
-- account in no organization — every personal user — is barred from nothing.

-- Which of these people may not have Nod act in a provider.
--
-- The array form is the primitive: `calendar-sync` sweeps two hundred accounts
-- per run and one round trip per account would spend the whole budget the sweep
-- has before it reaches a calendar.
create function public.users_barred_from_provider(p_users uuid[], p_provider text)
    returns table (user_id uuid)
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select distinct m.user_id
      from public.org_members m
      join public.org_integration_policies p
        on p.org_id = m.org_id
       and p.provider = p_provider
     where m.user_id = any(p_users)
       and m.status = 'active'
       and not p.is_allowed;
$$;

revoke all on function public.users_barred_from_provider(uuid[], text) from public, anon, authenticated;
grant execute on function public.users_barred_from_provider(uuid[], text) to service_role;

-- Whether one person may have Nod act in a provider, for the doors that have
-- one person in front of them.
create function public.user_may_use_provider(p_user uuid, p_provider text)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select not exists (
        select 1 from public.users_barred_from_provider(array[p_user], p_provider)
    );
$$;

-- Service role only, and deliberately not `authenticated`: the argument is a
-- user id, so a grant to every signed-in account would answer questions about
-- other people's employers. The client needs no grant — it reads the policy
-- rows themselves, scoped by row-level security to its own organizations.
revoke all on function public.user_may_use_provider(uuid, text) from public, anon, authenticated;
grant execute on function public.user_may_use_provider(uuid, text) to service_role;
