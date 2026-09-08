-- Two outcomes the row could not say.
--
-- A message, an event or a note a person sends from the card is written by
-- the form, not by `proposal-execute`, and until now the only way to close the
-- offer afterwards was `reject_proposal` — so work that happened was recorded
-- as declined, and the pattern miner counted every sent message as a refusal.
-- `settle_proposal` records it as `completed` with what the form got back.
--
-- Changing the verb on a row re-raises it under another type; `rejected` for
-- the old row was the same lie in the other direction. `withdrawn` is neither
-- a yes nor a no, the miner leaves it out, and the dedup index lets the same
-- work be offered again under the new type.
--
-- Expand only: a value is added to the status check, the index predicate
-- widens, two functions are added. Nothing an older client sends changes.

alter table public.action_proposals
    drop constraint if exists action_proposals_status_check;

alter table public.action_proposals
    add constraint action_proposals_status_check
    check (status in (
        'proposed', 'needs_review', 'ready',
        'approved', 'executing', 'completed', 'failed', 'rejected', 'withdrawn'
    ));

drop index if exists public.action_proposals_dedup_idx;
create unique index action_proposals_dedup_idx
    on public.action_proposals (meeting_id, type, md5(parameters::text))
    where meeting_id is not null and status not in ('rejected', 'withdrawn');

create function public.settle_proposal(
    p_proposal uuid,
    p_provider text,
    p_key text,
    p_url text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.action_proposals;
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
    if p_provider <> split_part(v_row.type, '.', 1) then
        raise exception 'that proposal is for %, not %', split_part(v_row.type, '.', 1), p_provider
            using errcode = '22023';
    end if;

    update public.action_proposals
       set status = 'completed',
           decided_at = now(),
           decided_by = auth.uid(),
           executed_at = now(),
           external_provider = p_provider,
           external_key = p_key,
           external_url = p_url,
           failure_code = null,
           failure_message = null
     where id = p_proposal;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    select v_row.org_id, auth.uid(), 'proposal.executed', 'action_proposal', p_proposal,
           jsonb_build_object('type', v_row.type, 'external_key', p_key, 'settled_by_person', true)
     where v_row.org_id is not null;
end;
$$;

create function public.withdraw_proposal(p_proposal uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.action_proposals;
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

    update public.action_proposals
       set status = 'withdrawn', decided_at = now(), decided_by = auth.uid()
     where id = p_proposal;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    select v_row.org_id, auth.uid(), 'proposal.withdrawn', 'action_proposal', p_proposal,
           jsonb_build_object('type', v_row.type)
     where v_row.org_id is not null;
end;
$$;

revoke all on function public.settle_proposal(uuid, text, text, text) from public, anon;
revoke all on function public.withdraw_proposal(uuid) from public, anon;
grant execute on function public.settle_proposal(uuid, text, text, text) to authenticated;
grant execute on function public.withdraw_proposal(uuid) to authenticated;
