-- Prepared work, before it is work.
--
-- Filing an action item in Linear already exists, and it is one item, one press,
-- one product — the user opens a draft, edits a title, sends it. That shape does
-- not survive the case this product is for: a meeting ends having produced five
-- things at once, two of them naming other people, and they are reviewed minutes
-- after the sentence that caused them. Those need somewhere to live between
-- being noticed and being done.
--
-- Separate from `action_items` rather than columns on it, for reasons that do
-- not reduce to each other:
--
--   * one item produces several actions — file the issue, invite the people;
--   * an action carries typed parameters, and an action item is deliberately a
--     line of text;
--   * `done` on a checklist and `completed` in a tracker are different facts;
--   * a proposal can come from the chat, with no meeting behind it at all.
--
-- And one that matters more than all of them. `20260806164035` refused an
-- assignee column on `action_items`, because naming somebody means publishing a
-- claim about a person who is not the user. That reasoning is intact and this
-- table is what it implies: a claim about another person belongs in an object
-- whose entire purpose is to be confirmed before it becomes true anywhere.
--
-- `type` is `provider.action`, which is exactly how `registry.ts` already
-- dispatches. Nothing here learns a provider's name.

create table public.action_proposals (
    id             uuid        primary key default gen_random_uuid(),
    -- Who will be asked. Not who it is about — that lives in the parameters.
    user_id        uuid        not null references auth.users(id) on delete cascade,
    org_id         uuid        references public.organizations(id),
    meeting_id     uuid        references public.meetings(id) on delete cascade,
    action_item_id uuid        references public.action_items(id) on delete set null,

    type   text not null check (type in (
        'linear.create_issue',
        'linear.update_issue',
        'google-calendar.create_event'
    )),

    -- `proposed` is a guess nobody has looked at; `needs_review` is missing
    -- something a person has to supply; `ready` could be approved as it stands.
    -- Approval is the human act, and everything after it is the server's.
    status text not null default 'proposed' check (status in (
        'proposed', 'needs_review', 'ready',
        'approved', 'executing', 'completed', 'failed', 'rejected'
    )),

    -- What the model asked for, kept as it asked for it. People inside are
    -- `people.id`, never names — a proposal that said "Alex" would be a string
    -- somebody has to resolve again at the worst possible moment.
    parameters jsonb not null default '{}'::jsonb,
    -- The same thing after identity resolution, written by the executor. Kept
    -- apart so a failed execution can be read against what was actually sent
    -- rather than against what was meant.
    resolved_parameters jsonb,

    -- Composed from parts the resolver measures, with the model's own opinion as
    -- one input among them. Advisory: it orders and labels the review queue and
    -- decides nothing on its own, because the client computes it and the client
    -- is also what decided to propose. Everything that must be true before this
    -- executes is re-checked server-side by `proposal-execute`.
    confidence       numeric(3, 2) check (confidence is null or confidence between 0 and 1),
    confidence_parts jsonb,

    -- The transcript entry that caused it (`meeting_transcripts.idx`), the same
    -- anchor `action_items.evidence_idx` uses. It is what makes a proposal
    -- answerable — "because this was said, here" — and it cannot be recovered
    -- later.
    evidence_idx integer,

    created_at  timestamptz not null default now(),
    decided_at  timestamptz,
    decided_by  uuid references auth.users(id) on delete set null,
    executed_at timestamptz,

    -- The same three words every provider action already answers with, so a row
    -- that was filed reads identically to one filed through the older per-item
    -- path (`20260812195722`).
    external_provider text,
    external_key      text,
    external_url      text,

    failure_code    text,
    failure_message text
);

-- The review queue: what is still waiting on me.
create index action_proposals_pending_idx
    on public.action_proposals (user_id, created_at desc)
    where status in ('proposed', 'needs_review', 'ready');

create index action_proposals_meeting_idx on public.action_proposals (meeting_id)
    where meeting_id is not null;

-- The same action proposed twice for one meeting is one action. `jsonb::text`
-- is canonical — keys sorted, whitespace normalized — so two identical proposals
-- hash the same however the model happened to order its keys.
--
-- Rejected rows are excluded so that saying no once does not make the meeting
-- unable to propose it again after an edit.
create unique index action_proposals_dedup_idx
    on public.action_proposals (meeting_id, type, md5(parameters::text))
    where meeting_id is not null and status <> 'rejected';

-- ── Which organization this belongs to ──────────────────────────────────────
--
-- Not the parent-copy trigger the content tables use: a proposal may have no
-- meeting behind it (the chat proposes things too), and then the answer is the
-- context the person is working in. Both paths verify membership rather than
-- trusting what arrived, because `org_id` is what the audit trail is filed
-- under and what decides whose people may be named.
create function public._stamp_proposal_org()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    if new.meeting_id is not null then
        select m.org_id into v_org from public.meetings m where m.id = new.meeting_id;
    else
        select p.active_org_id into v_org from public.profiles p where p.user_id = new.user_id;
    end if;

    if v_org is not null and not public._is_org_member_of(v_org, new.user_id) then
        v_org := null;
    end if;

    new.org_id := v_org;
    return new;
end;
$$;

revoke all on function public._stamp_proposal_org() from public, anon, authenticated;

create trigger stamp_proposal_org before insert on public.action_proposals
    for each row execute function public._stamp_proposal_org();

-- ── Reading and proposing ───────────────────────────────────────────────────

alter table public.action_proposals enable row level security;

create policy "owners read their proposals"
    on public.action_proposals for select to authenticated
    using ((select auth.uid()) = user_id);

-- Proposing is a client act — it is the client that heard the meeting. What a
-- client cannot do is move a proposal along: `status` is not writable from here,
-- so the only way past `proposed` is through the functions below.
create policy "owners raise their own proposals"
    on public.action_proposals for insert to authenticated
    with check ((select auth.uid()) = user_id and status in ('proposed', 'needs_review', 'ready'));

grant select, insert on table public.action_proposals to authenticated;
grant select, update on table public.action_proposals to service_role;

-- ── Deciding ────────────────────────────────────────────────────────────────

-- Approving and editing are one act, because they are one moment: the person
-- reads what is proposed, changes what is wrong, and says yes to the result.
-- Splitting them would let an approval refer to a version nobody approved.
create function public.approve_proposal(p_proposal uuid, p_parameters jsonb default null)
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
    -- Approving something already running is how one meeting becomes two Linear
    -- issues. The states that may still be approved are the ones nobody has
    -- acted on.
    if v_row.status not in ('proposed', 'needs_review', 'ready') then
        raise exception 'that proposal is already %', v_row.status using errcode = '22023';
    end if;

    update public.action_proposals
       set parameters = coalesce(p_parameters, parameters),
           status     = 'approved',
           decided_at = now(),
           decided_by = auth.uid(),
           failure_code = null,
           failure_message = null
     where id = p_proposal;

    if v_row.org_id is not null then
        insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
        values (v_row.org_id, auth.uid(), 'proposal.approved', 'action_proposal', p_proposal,
                jsonb_build_object('type', v_row.type, 'edited', p_parameters is not null));
    end if;
end;
$$;

-- Answering a question the proposal asked, without answering the proposal.
--
-- Naming the owner Nod could not resolve is an edit, not an approval: the
-- person may still want to fix the title, or decide the task should not exist.
-- Folding it into `approve_proposal` would make settling one question commit
-- them to the rest.
--
-- `status` is supplied rather than derived here, and that is the same trust the
-- insert policy already places in the client: the thresholds that turn measured
-- confidence into a state live in one place in the app, and a second copy in SQL
-- would drift from it. Both ends are bounded to the three states nobody has
-- acted on yet, so nothing here can move a proposal towards execution.
create function public.edit_proposal(
    p_proposal   uuid,
    p_parameters jsonb,
    p_confidence numeric default null,
    p_status     text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_status text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_status is not null and p_status not in ('proposed', 'needs_review', 'ready') then
        raise exception 'a proposal cannot be edited into %', p_status using errcode = '42501';
    end if;

    select status into v_status from public.action_proposals
     where id = p_proposal and user_id = auth.uid();
    if not found then
        raise exception 'no such proposal' using errcode = '42704';
    end if;
    if v_status not in ('proposed', 'needs_review', 'ready') then
        raise exception 'that proposal is already %', v_status using errcode = '22023';
    end if;

    update public.action_proposals
       set parameters = coalesce(p_parameters, parameters),
           confidence = coalesce(p_confidence, confidence),
           status     = coalesce(p_status, status)
     where id = p_proposal;
end;
$$;

create function public.reject_proposal(p_proposal uuid)
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
    -- A proposal that already ran cannot be un-run by saying no to it, and
    -- pretending otherwise would leave a rejected row pointing at a live issue.
    if v_row.status in ('executing', 'completed') then
        raise exception 'that proposal is already %', v_row.status using errcode = '22023';
    end if;

    update public.action_proposals
       set status = 'rejected', decided_at = now(), decided_by = auth.uid()
     where id = p_proposal;

    if v_row.org_id is not null then
        insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
        values (v_row.org_id, auth.uid(), 'proposal.rejected', 'action_proposal', p_proposal,
                jsonb_build_object('type', v_row.type));
    end if;
end;
$$;

revoke all on function public.approve_proposal(uuid, jsonb) from public, anon;
revoke all on function public.edit_proposal(uuid, jsonb, numeric, text) from public, anon;
revoke all on function public.reject_proposal(uuid) from public, anon;
grant execute on function public.approve_proposal(uuid, jsonb) to authenticated;
grant execute on function public.edit_proposal(uuid, jsonb, numeric, text) to authenticated;
grant execute on function public.reject_proposal(uuid) to authenticated;

-- ── Who a proposal may name ─────────────────────────────────────────────────

-- The person behind an assignment, and whether they can actually be addressed
-- in the product this proposal targets.
--
-- Answered here rather than in the executor because it is the same question the
-- review UI asks before it draws "Owner: unresolved" — and two implementations
-- of "can this person be assigned" would disagree the first time one of them
-- learned about a new provider.
create function public.person_identity_for(p_person uuid, p_provider text)
    returns table (external_id text, handle text, display_name text)
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select pi.external_id, pi.handle, pe.display_name
      from public.person_identities pi
      join public.people pe on pe.id = pi.person_id
     where pi.person_id = p_person
       and pi.provider = p_provider
       and pe.deleted_at is null
       and public.is_org_member(pe.org_id)
     limit 1;
$$;

revoke all on function public.person_identity_for(uuid, text) from public, anon;
grant execute on function public.person_identity_for(uuid, text) to authenticated;
