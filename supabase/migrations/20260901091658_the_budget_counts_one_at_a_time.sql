-- Serialise budget consumption: two proposals approved in the same instant
-- could both read a budget with one slot left and both take it. Locking the
-- grant row makes the count-then-approve read-modify-write atomic per grant.
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
     limit 1
     for update;
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
