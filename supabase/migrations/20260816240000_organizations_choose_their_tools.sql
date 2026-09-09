-- An organization decides which tools Nod may act in.
--
-- Until now the only gate on acting in a third-party product was whether the
-- person had connected it. That is the individual's decision, and it is not the
-- one a company is asking about: an employer that standardised on Teams does not
-- want work appearing in somebody's personal Slack, and an employer with a
-- data-residency rule does not want it appearing in either. `34. External Action
-- Security` names this explicitly — an action must validate that "the
-- organization permits the integration" — and nothing did.
--
-- Absence means allowed, not denied. Every organization that exists today has no
-- row here, and default-deny would silently stop integrations that are working
-- right now for people who never asked for a policy. The switch is opt-in
-- tightening, which is what a control that arrives after the feature has to be.
--
-- Per provider rather than per capability. "We use Linear" and "we do not use
-- Slack" are the sentences administrators actually say; a capability-level
-- switch would make the answer to "may Nod create a channel" depend on which
-- adapter happened to be installed.

create table public.org_integration_policies (
    org_id     uuid        not null references public.organizations(id) on delete cascade,
    -- Deliberately unconstrained against a provider list. A policy is a
    -- statement about a tool, and an administrator must be able to have made it
    -- before the adapter ships — otherwise every new integration arrives
    -- switched on for everybody by default, which is the outcome this table
    -- exists to prevent.
    provider   text        not null check (length(btrim(provider)) between 1 and 64),
    is_allowed boolean     not null default true,
    updated_by uuid        references auth.users(id) on delete set null,
    updated_at timestamptz not null default now(),
    primary key (org_id, provider)
);

alter table public.org_integration_policies enable row level security;

-- Members read it, because the app has to know what it may offer before it
-- offers it — a button that fails on press is worse than one that was never
-- drawn. Only administrators write, and only through the function below.
create policy "members read their org integration policy"
    on public.org_integration_policies for select to authenticated
    using ((select public.is_org_member(org_id)));

grant select on table public.org_integration_policies to authenticated;

-- Whether this organization permits acting in a provider at all.
--
-- Answers true for a null organization, which is every personal account: a
-- person working outside any company is governed by nobody, and their own
-- connection is the whole of the decision.
create function public.org_allows_provider(p_org uuid, p_provider text)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select coalesce(
        (select is_allowed from public.org_integration_policies
          where org_id = p_org and provider = p_provider),
        true
    );
$$;

revoke all on function public.org_allows_provider(uuid, text) from public, anon;
grant execute on function public.org_allows_provider(uuid, text) to authenticated, service_role;

create function public.set_org_integration_policy(p_org uuid, p_provider text, p_allowed boolean)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform public._assert_org_admin(p_org);

    insert into public.org_integration_policies (org_id, provider, is_allowed, updated_by)
    values (p_org, btrim(p_provider), p_allowed, auth.uid())
    on conflict (org_id, provider) do update
       set is_allowed = excluded.is_allowed,
           updated_by = excluded.updated_by,
           updated_at = now();

    insert into public.audit_log (org_id, actor_user_id, action, target_type, metadata)
    values (p_org, auth.uid(), 'integration.policy_set', 'integration',
            jsonb_build_object('provider', btrim(p_provider), 'allowed', p_allowed));
end;
$$;

revoke all on function public.set_org_integration_policy(uuid, text, boolean) from public, anon;
grant execute on function public.set_org_integration_policy(uuid, text, boolean) to authenticated;

-- ── The gate, where it cannot be skipped ────────────────────────────────────
--
-- On approval rather than only in the executor. An approved proposal is a
-- decision on the record, and letting one be recorded for a tool the
-- organization has forbidden would mean the audit log says a person approved
-- something that was never permitted. The executor checks again, because a
-- policy can change between approving and running.
create or replace function public.approve_proposal(p_proposal uuid, p_parameters jsonb default null)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.action_proposals;
    v_provider text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select * into v_row from public.action_proposals
     where id = p_proposal and user_id = auth.uid();
    if not found then
        raise exception 'no such proposal' using errcode = '42704';
    end if;
    if v_row.status not in ('proposed', 'needs_review', 'ready') then
        raise exception 'that proposal is already %', v_row.status using errcode = '22023';
    end if;

    v_provider := split_part(v_row.type, '.', 1);
    if v_row.org_id is not null and not public.org_allows_provider(v_row.org_id, v_provider) then
        raise exception 'your organization does not allow Nod to act in %', v_provider
            using errcode = '42501';
    end if;

    update public.action_proposals
       set parameters = coalesce(p_parameters, parameters),
           status     = 'approved',
           decided_at = now(),
           decided_by = auth.uid(),
           failure_code = null,
           failure_message = null
     where id = p_proposal;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    select v_row.org_id, auth.uid(), 'proposal.approved', 'action_proposal', p_proposal,
           jsonb_build_object('type', v_row.type, 'edited', p_parameters is not null)
     where v_row.org_id is not null;
end;
$$;

revoke all on function public.approve_proposal(uuid, jsonb) from public, anon;
grant execute on function public.approve_proposal(uuid, jsonb) to authenticated;
