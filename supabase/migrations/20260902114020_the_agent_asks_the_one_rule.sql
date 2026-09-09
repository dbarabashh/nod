-- The agent's approval asks what every other approval asks.
--
-- `20260827160000` put the organization policy on the server as
-- `user_may_use_provider` — a forbidding organization forbids, whichever other
-- memberships the person holds — and `20260827170000` made it the only
-- expression of the rule by moving `approve_proposal` onto it.
-- `agent_approve_proposal` arrived later and reached for the retired
-- `org_allows_provider` instead: one organization, and skipped entirely when
-- the proposal carried none. So a standing grant could approve, unattended,
-- in a provider that one of the person's employers had switched off — the
-- exact drift the shared rule was written to end.
--
-- Only the policy check changes; the rest is `20260901094513`'s function
-- unaltered, because a `create or replace` has to carry the whole body. The
-- refusal stays a verdict word rather than `approve_proposal`'s exception:
-- this function's contract is that the client acts on the word, never on
-- error prose, and a forbidden provider needs no distinct client behaviour.
--
-- With that, `org_allows_provider` has no caller left in any migration,
-- policy, trigger or view, and its retirement finishes here. The one caller
-- it ever had outside the database was `proposal-execute`, which stopped
-- asking in the deploy that shipped `20260827170000`; apply this only to an
-- instance whose `proposal-execute` is at or after that deploy. Rollback is
-- `20260816240000`'s `create function` granted to `service_role` only — its
-- `authenticated` grant was the hole `20260827170000` closed — plus
-- `20260901094513`'s body.

create or replace function public.agent_approve_proposal(p_proposal uuid)
returns text
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
    if not found or v_row.raised_by_agent is null
       or v_row.status not in ('proposed', 'ready') then
        return 'refused';
    end if;

    select * into v_agent from public.agents
     where id = v_row.raised_by_agent and user_id = auth.uid();
    if not found or v_agent.status <> 'active' or v_agent.trust <> 'l3' then
        return 'refused';
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
        return 'grant_expired';
    end if;

    select count(*) into v_used
      from public.action_proposals
     where raised_by_agent = v_agent.id
       and auto_approved
       and decided_at > now() - interval '7 days';
    if v_used >= v_grant.per_week then
        return 'grant_budget_spent';
    end if;

    v_provider := split_part(v_row.type, '.', 1);
    if not public.user_may_use_provider(v_row.user_id, v_provider) then
        return 'refused';
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

    return 'approved';
end;
$$;

revoke all on function public.agent_approve_proposal(uuid) from public, anon;
grant execute on function public.agent_approve_proposal(uuid) to authenticated;

drop function if exists public.org_allows_provider(uuid, text);
