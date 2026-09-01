-- Post-review cleanup, four findings with one home.
--
-- 1. Distillation coverage becomes the server's fact: `meetings.distilled_at`
--    is stamped by the distiller, so the client's backfill asks one indexed
--    question instead of downloading every concept's meeting id — and a
--    session that honestly distilled to nothing stops being re-distilled
--    (a paid model call) on every launch forever.
-- 2. The miner now reads the observations ledger it was always documented as
--    reading, instead of reaching past it into `action_proposals` — the view
--    gains its first real reader, and future streams (tool approvals) join
--    the count by appearing in the view rather than by editing the miner.
-- 3. `agent_approve_proposal` answers with a verdict instead of an exception:
--    the client was string-matching error text to tell a lapsed grant from a
--    hard failure, which is exactly the coupling `apply_concept`'s `decision`
--    column already avoids. Return-type changes need a drop, so the function
--    is re-granted below.
-- 4. Accepting a pattern becomes one transaction. It was an RPC plus a client
--    insert; a crash between the two left the candidate `accepted` with no
--    agent behind it — and a dismissed-forever unique row meant the habit
--    could never be offered again.
--
-- `concept_history` goes: nothing calls it, and the repo's own rule is that
-- an abstraction earns its place with callers, not with plans.

alter table public.meetings
    add column distilled_at timestamptz;

drop function public.concept_history(uuid);

create or replace function public.mine_pattern_candidates(
    p_user_id uuid,
    p_min_support integer default 3,
    p_min_precision numeric default 0.8,
    p_min_span interval default '21 days',
    p_window interval default '90 days'
)
returns setof public.pattern_candidates
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    with decided as (
        select
            o.context_key,
            count(*) filter (where o.kind in ('proposal_approved', 'proposal_completed')) as approvals,
            count(*) filter (where o.kind = 'proposal_rejected')                          as rejections,
            min(o.at)                                                                     as first_at,
            max(o.at)                                                                     as last_at
        from public.observations o
        where o.user_id = p_user_id
          and o.at > now() - p_window
          and o.kind like 'proposal\_%'
        group by o.context_key
    ),
    qualifying as (
        select * from decided
        where approvals >= p_min_support
          and last_at - first_at >= p_min_span
          and approvals::numeric / (approvals + rejections) >= p_min_precision
    )
    insert into public.pattern_candidates as pc
        (user_id, context_key, support, rejected, first_at, last_at)
    select p_user_id, q.context_key, q.approvals, q.rejections, q.first_at, q.last_at
      from qualifying q
    on conflict (user_id, context_key) do update
       set support = excluded.support,
           rejected = excluded.rejected,
           last_at = excluded.last_at,
           updated_at = now()
        where pc.status in ('candidate', 'offered')
    returning pc.*;
end;
$$;

-- One transaction from habit to agent. Everything `accept` used to decide
-- client-side — l2 for a proposal-shaped habit, the draft type — is decided
-- here, beside the constraint that enforces it.
create or replace function public.accept_pattern_into_agent(
    p_candidate uuid,
    p_title text,
    p_prompt text
)
returns setof public.agents
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_candidate public.pattern_candidates;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    update public.pattern_candidates
       set status = 'accepted', updated_at = now()
     where id = p_candidate
       and user_id = auth.uid()
       and status in ('candidate', 'offered')
    returning * into v_candidate;
    if not found then
        return;
    end if;

    return query
        insert into public.agents (user_id, title, prompt, origin_pattern, trust, draft_type)
        values (
            auth.uid(),
            p_title,
            p_prompt,
            v_candidate.id,
            case when v_candidate.context_key like '%.%' then 'l2' else 'l1' end,
            case when v_candidate.context_key like '%.%' then v_candidate.context_key end
        )
        returning *;
end;
$$;

-- A verdict, not an exception: the caller acts on the word, never on error
-- prose. Refusal reasons that need no distinct client behaviour collapse into
-- 'refused'.
drop function public.agent_approve_proposal(uuid);

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
    if v_row.org_id is not null and not public.org_allows_provider(v_row.org_id, v_provider) then
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

revoke all on function public.accept_pattern_into_agent(uuid, text, text) from public, anon;
revoke all on function public.agent_approve_proposal(uuid) from public, anon;
grant execute on function public.accept_pattern_into_agent(uuid, text, text) to authenticated;
grant execute on function public.agent_approve_proposal(uuid) to authenticated;
