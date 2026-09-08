-- A filing that failed can be approved again.
--
-- The card offers "Try again" on a failed row, and `proposal-execute` runs only
-- what is `approved` — so the retry has to pass through approval, and approval
-- refused anything but a fresh offer. Same body as `20260827170000`, with
-- `failed` admitted; a `create or replace` has to carry the whole function.
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
    if v_row.status not in ('proposed', 'needs_review', 'ready', 'failed') then
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
