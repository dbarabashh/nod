-- One expression of the policy, for the three questions that ask it.
--
-- `20260827160000` put the rule on the server but left two other derivations of
-- it standing, and both had already drifted:
--
--   * `approve_proposal` still asked `org_allows_provider(proposal.org_id, …)` —
--     one organization, and skipped entirely when the proposal carried none.
--     `proposal-execute` asks about the person. So somebody in a permissive
--     organization and a forbidding one could get a proposal *approved*, and
--     `audit_log` would record an approval for a tool that was never permitted,
--     which is the exact outcome the approval-time check was added to prevent.
--   * The desktop client derives its own answer by reading the policy rows and
--     leaning on that table's `using ((select public.is_org_member(org_id)))`
--     to supply the membership half. It agrees with the server today only
--     because `is_org_member` also says `status = 'active'` — two predicates
--     maintained apart, with nothing that fails when they diverge. `20260827160000`
--     could only warn about this in prose.
--
-- Both now call the rule instead of restating it. `my_blocked_providers` is the
-- client's shape: argument-free, so the objection that barred the array form
-- from `authenticated` — that it would answer about other people's employers —
-- does not apply. It can only answer about its caller.
--
-- Deploy order: this before the client that calls `my_blocked_providers`. An
-- older client keeps reading the table and is unaffected; a newer client on an
-- instance without this function logs and permits everything, which is what
-- `loadBlockedProviders` already does with any failure.

-- What the signed-in person's organizations forbid.
create function public.my_blocked_providers()
    returns table (provider text)
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select distinct p.provider
      from public.org_members m
      join public.org_integration_policies p on p.org_id = m.org_id
     where m.user_id = (select auth.uid())
       and m.status = 'active'
       and not p.is_allowed;
$$;

revoke all on function public.my_blocked_providers() from public, anon;
grant execute on function public.my_blocked_providers() to authenticated;

-- Approval asks what execution asks.
--
-- Only the policy check changes; the rest is `20260816240000`'s function
-- unaltered, because a `create or replace` has to carry the whole body.
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
    if not public.user_may_use_provider(v_row.user_id, v_provider) then
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

-- `org_allows_provider` now has no caller, and while it stands it is a hole:
-- it takes an arbitrary organization id and is granted to `authenticated`, so
-- any signed-in account can enumerate any organization's integration policy.
-- The grant goes now; the function stays until a contract migration can drop it
-- with the rest of its retirement, and `security definer` callers of the future
-- are unaffected by a revoke.
revoke execute on function public.org_allows_provider(uuid, text) from authenticated;
