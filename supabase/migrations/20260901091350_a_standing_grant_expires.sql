-- L3: standing authority, held by the server.
--
-- A grant is a row — one provider, one action, a weekly rate, an expiry, a
-- named granter — and the only path from "an agent drafted this" to "it was
-- approved with nobody watching" is `agent_approve_proposal`, which re-checks
-- every claim against that row at the moment of use. The client asks; it never
-- decides. Trust set to l3 by hand without a live grant changes nothing,
-- because the trust column was never the gate.
--
-- Expiry is the recertification: authority lapses on its own, the agent goes
-- back to asking, and renewal is the same explicit act the first grant was.

alter table public.action_proposals
    add column auto_approved boolean not null default false;

create index action_proposals_auto_idx
    on public.action_proposals (raised_by_agent, decided_at)
    where auto_approved;

-- The one way to mint standing authority. Requires an L2 agent with a draft
-- type: the grant covers exactly the shape the habit earned, nothing wider.
create or replace function public.grant_agent_authority(
    p_agent uuid,
    p_days integer default 90,
    p_per_week integer default 5
)
returns setof public.agent_grants
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_agent public.agents;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_days < 1 or p_days > 365 then
        raise exception 'grant length must be between 1 and 365 days';
    end if;

    select * into v_agent
      from public.agents
     where id = p_agent and user_id = auth.uid()
       for update;
    if not found then
        raise exception 'no such agent' using errcode = '42704';
    end if;
    if v_agent.trust not in ('l2', 'l3') or v_agent.draft_type is null then
        raise exception 'only a drafting agent can hold a standing grant';
    end if;

    -- One live grant per agent: renewing revokes the old one rather than
    -- stacking authorities whose sum nobody agreed to.
    update public.agent_grants
       set revoked_at = now()
     where agent_id = p_agent and revoked_at is null;

    update public.agents
       set trust = 'l3', updated_at = now()
     where id = p_agent;

    return query
        insert into public.agent_grants
            (agent_id, user_id, provider, action, per_week, expires_at, granted_by)
        values (
            p_agent,
            auth.uid(),
            split_part(v_agent.draft_type, '.', 1),
            split_part(v_agent.draft_type, '.', 2),
            p_per_week,
            now() + make_interval(days => p_days),
            auth.uid()
        )
        returning *;
end;
$$;

create or replace function public.revoke_agent_grant(p_agent uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    update public.agent_grants
       set revoked_at = now()
     where agent_id = p_agent and user_id = auth.uid() and revoked_at is null;
    update public.agents
       set trust = 'l2', updated_at = now()
     where id = p_agent and user_id = auth.uid() and trust = 'l3';
end;
$$;

-- The moment of use. Approves an agent-drafted proposal with nobody watching,
-- and only when every claim still holds RIGHT NOW: the agent is active and
-- trusted, the grant is alive, the type is exactly the granted shape, the
-- weekly budget has room, and the organization still permits the provider.
-- `needs_review` is excluded on principle: a draft missing something only a
-- person can supply must wait for the person, whatever the grant says.
create or replace function public.agent_approve_proposal(p_proposal uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row public.action_proposals;
    v_agent public.agents;
    v_grant public.agent_grants;
    v_used integer;
    v_provider text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select * into v_row from public.action_proposals
     where id = p_proposal and user_id = auth.uid()
       for update;
    if not found then
        raise exception 'no such proposal' using errcode = '42704';
    end if;
    if v_row.raised_by_agent is null then
        raise exception 'not an agent draft';
    end if;
    if v_row.status not in ('proposed', 'ready') then
        raise exception 'that proposal is already %', v_row.status using errcode = '22023';
    end if;

    select * into v_agent from public.agents
     where id = v_row.raised_by_agent and user_id = auth.uid();
    if not found or v_agent.status <> 'active' or v_agent.trust <> 'l3' then
        raise exception 'agent_not_standing' using errcode = '42501';
    end if;

    select * into v_grant from public.agent_grants
     where agent_id = v_agent.id
       and revoked_at is null
       and expires_at > now()
       and provider = split_part(v_row.type, '.', 1)
       and action = split_part(v_row.type, '.', 2)
     order by created_at desc
     limit 1;
    if not found then
        raise exception 'grant_expired' using errcode = '42501';
    end if;

    select count(*) into v_used
      from public.action_proposals
     where raised_by_agent = v_agent.id
       and auto_approved
       and decided_at > now() - interval '7 days';
    if v_used >= v_grant.per_week then
        raise exception 'grant_budget_spent' using errcode = '42501';
    end if;

    v_provider := split_part(v_row.type, '.', 1);
    if v_row.org_id is not null and not public.org_allows_provider(v_row.org_id, v_provider) then
        raise exception 'your organization does not allow Nod to act in %', v_provider
            using errcode = '42501';
    end if;

    update public.action_proposals
       set status = 'approved',
           decided_at = now(),
           decided_by = auth.uid(),
           auto_approved = true,
           failure_code = null,
           failure_message = null
     where id = p_proposal;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    select v_row.org_id, auth.uid(), 'proposal.auto_approved', 'action_proposal', p_proposal,
           jsonb_build_object('type', v_row.type, 'agent', v_agent.id, 'grant', v_grant.id)
     where v_row.org_id is not null;
end;
$$;

revoke all on function public.grant_agent_authority(uuid, integer, integer) from public, anon;
revoke all on function public.revoke_agent_grant(uuid) from public, anon;
revoke all on function public.agent_approve_proposal(uuid) from public, anon;

grant execute on function public.grant_agent_authority(uuid, integer, integer) to authenticated;
grant execute on function public.revoke_agent_grant(uuid) to authenticated;
grant execute on function public.agent_approve_proposal(uuid) to authenticated;
