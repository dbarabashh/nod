-- A session that stops existing stops being on screen, everywhere at once.
--
-- `20260815100636` pushes when *permission* moves — a membership, a folder
-- share, a team. It says nothing when the thing itself moves, and that is the
-- gap somebody hits within a minute of installing the phone: delete a voice note
-- on iOS and the Mac keeps drawing it until its own 30-second throttle expires
-- and something happens to call `refresh`. The row was unreadable on the server
-- the whole time; only the window disagreed.
--
-- The same gap has a second, sharper edge in an organization. Filing a session
-- into a shared folder is what grants a colleague access to it, and unfiling is
-- what takes it back — but `meeting_labels` broadcast nothing, so the colleague
-- kept an openable session they were no longer entitled to read. Not a leak: the
-- next query refuses them. A stale window that offers a door already locked.
--
-- Two triggers, both sending the contentless `access` poke the existing channel
-- already listens for. Nothing new travels; the client re-asks under its own
-- permissions, and a poke to somebody who lost access shows them nothing they
-- could not already have queried for themselves.
--
-- Who has to hear it: the owner (their other devices — the phone-then-Mac case),
-- plus every audience the session actually reaches, which is both mechanisms —
-- `meeting_grants` for one call handed to a team, `folder_shares` through
-- `meeting_labels` for everything filed under a shared folder. Audience topics
-- rather than one message per member, matching the existing senders exactly.
--
-- The audience query is written out inside each trigger rather than factored
-- into a helper. A shared `topics_for(meeting)` would be a SECURITY DEFINER
-- function that takes any uuid and answers which teams and organizations a
-- session is shared with — an oracle sitting one stray `grant` away from being
-- readable, and one this repo's own rule would then require to re-derive the
-- authorization its callers already hold. Two copies of six lines is the
-- cheaper thing to own.
--
-- Deliberately silent on a session *appearing*. There is no `after insert` on
-- `meetings`: a recording writes its row before the first word is spoken, and
-- pushing that would put a blank in-progress session on every other device of a
-- person who is still talking. Arrival is what the ordinary refresh is for; this
-- migration is about removal, which is the half a refresh cannot make timely.
--
-- The event stays `access` with the payload it already had. A `reason` telling a
-- client whether its permissions changed or somebody merely filed something
-- would let a future build refresh less, but no build reads the payload today
-- and none is waiting on one — a vocabulary with no second word yet. Both
-- shipped clients treat the poke as "re-ask", which stays correct; what changes
-- is how often, and the client-side collapse of a burst is where that is paid.
--
-- Deploy order and rollback. Additive and one-sided: a client that never
-- subscribes never hears these, and one that does runs the refresh it already
-- ran on a timer. Apply before or after any client ships; roll back by dropping
-- the three objects below. Nothing depends on a poke arriving, so there is no
-- retirement gate and no legacy path to remove later.
--
-- Belongs to the sandbox-only sharing lineage (`20260814152612` onward) and can
-- only apply where that lineage already did. The assertion below turns "half of
-- this landed on a branch that predates it" — which would leave triggers on
-- `meetings` calling a function that does not exist, and no user able to delete
-- a recording — into a clean, whole-transaction failure with a legible message.

do $$
begin
    if to_regprocedure('public._notify_access_changed(text)') is null
       or to_regclass('public.folder_shares') is null
       or to_regclass('public.meeting_grants') is null then
        raise exception
            'access broadcasting is not set up on this branch: apply the organization sharing migrations (20260814152612 onward) first';
    end if;
end $$;

-- ── The session itself ──────────────────────────────────────────────────────

-- The send is inside a handler, not just `realtime.send` itself.
-- `_notify_access_changed` guards its own insert for a stated reason — "a poke
-- that cannot be sent must never take the transaction with it" — and that
-- reason covers the lookup deciding where to send just as much: this reads three
-- tables to answer a question nobody asked for, and a lock wait or a missing
-- relation there would abort somebody's delete.
--
-- Not every failure, and the gap is worth knowing: `when others` does not catch
-- `query_canceled`, so a `statement_timeout` landing inside the send loop still
-- takes the write with it. Buying that back means a per-trigger timeout, which
-- is a knob with no evidence behind it yet.
--
-- Nothing at all when the owner is already gone. An account erasure cascades
-- from `auth.users` through every meeting the person recorded, and one deletion
-- would otherwise emit a message per recording. There is nobody left to tell,
-- and the audiences of anything shared are told by the `meeting_grants` and
-- `folder_shares` cascades that fire alongside.
--
-- The guard sits in the outer block, which has no `exception` clause, and the
-- sending sits in an inner block that does. That shape is the point, not a
-- style: PL/pgSQL allocates a subtransaction on *entry* to any block with a
-- handler, before a line of it runs, so a guard inside one still costs a subxid
-- per row. Past 64 in a transaction the subxid cache overflows and every
-- concurrent backend starts reading `pg_subtrans` — a cluster-wide latency
-- event caused by one person deleting their account. This way the bulk paths
-- return before any handler exists, and an ordinary single delete allocates
-- exactly one.
--
-- The trade the outer block makes: an error in the `auth.users` probe itself
-- would abort the write rather than be swallowed. That probe is a primary-key
-- lookup on a table this function's owner is granted, so it fails only if the
-- grant is taken away — a condition that should be loud rather than a feature
-- that silently stops working, which is the same reason the handler below
-- raises a warning instead of returning quietly.
--
-- A trigger `when` clause cannot hold a subquery, or this would live there.
create function public._broadcast_meeting_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row   public.meetings := coalesce(new, old);
    v_topic text;
begin
    if not exists (select 1 from auth.users u where u.id = v_row.user_id) then
        return coalesce(new, old);
    end if;

    begin
        for v_topic in
            select 'user:' || v_row.user_id::text
            union
            select case
                       when g.team_id is not null then 'team:' || g.team_id::text
                       else 'org:' || g.org_id::text
                   end
              from public.meeting_grants g
             where g.meeting_id = v_row.id
            union
            select case
                       when fs.team_id is not null then 'team:' || fs.team_id::text
                       else 'org:' || fs.org_id::text
                   end
              from public.meeting_labels ml
              join public.folder_shares fs on fs.label_id = ml.label_id
             where ml.meeting_id = v_row.id
        loop
            perform public._notify_access_changed(v_topic);
        end loop;
    exception when others then
        -- Loud on the way down. A swallowed failure here is indistinguishable
        -- from "nobody needed telling", so the feature could be dead in
        -- production with no signal at all. A warning inside a handler does not
        -- abort the transaction.
        raise warning 'broadcast_meeting_change failed: %', sqlerrm;
    end;
    return coalesce(new, old);
end;
$$;

revoke all on function public._broadcast_meeting_change() from public, anon, authenticated, service_role;

-- Deliberately not every update. A recording writes to its own row several times
-- while it is being made — the end time, the title, the summary that lands after
-- it — and a poke on each of those would have every device in the organization
-- re-reading the library while one person is still talking. Only the two columns
-- that decide whether the row is in the list at all: `deleted_at` (trash and
-- restore, both directions) and `merged_into` (a recording absorbed into
-- another, which leaves the list the same way a deleted one does).
create trigger broadcast_access after update on public.meetings
    for each row
    when (
        old.deleted_at is distinct from new.deleted_at
        or old.merged_into is distinct from new.merged_into
    )
    execute function public._broadcast_meeting_change();

-- `before`, not `after`, and this is the one place the choice matters. The
-- audience of a session lives in `meeting_labels` and `meeting_grants`, both of
-- which cascade from this delete. After-triggers and referential-integrity
-- triggers share one queue ordered by name, so an `after delete` here would read
-- those children or not depending on how `broadcast_removal` happens to sort
-- against `RI_ConstraintTrigger_…` under the database's collation — audiences
-- notified twice on one machine and silently never on another. Before the delete
-- there is no ordering question: the children are still there.
--
-- Gated on the row having been live. The nightly purge is a single
-- `delete from public.meetings where deleted_at is not null and …` over every
-- account at once (`20260524105604`), and an ungated trigger would turn one cron
-- statement into a message per purged row per audience — a 03:00 storm about
-- sessions that left every list thirty days earlier, when `deleted_at` was
-- stamped and the update trigger above already said so. It would also be a count
-- anybody in the organization could sit and read off their own topic: how many
-- sessions their colleagues trashed, exactly thirty days ago. Nothing observable
-- changes when an invisible row is finally removed, so nothing is sent.
create trigger broadcast_removal before delete on public.meetings
    for each row
    when (old.deleted_at is null)
    execute function public._broadcast_meeting_change();

-- ── Filing and unfiling ─────────────────────────────────────────────────────

-- Filing is a grant and unfiling is a revocation, so both send. The audience is
-- the folder's, and only the folder's — the meeting's other folders did not
-- change, and their audiences have nothing to re-ask for.
--
-- Nothing at all when the session is not in anybody's list. `on delete cascade`
-- brings the purge and the account erasure here too, one row per label per
-- removed session, and a link removed from a session nobody can see is not a
-- change anybody can see. The same test covers filing or unfiling something
-- already trashed, which `meeting_labels`' own insert policy permits and which
-- no audience could read either way.
--
-- The owner is sent last, and looked up rather than taken from `user_id` on the
-- link row: unfiling somebody else's session out of your own folder writes your
-- id there, and the person whose library changed is the one who recorded it.
create function public._broadcast_filing_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row   public.meeting_labels := coalesce(new, old);
    v_owner uuid;
    v_topic text;
begin
    -- Three ways this row can be disappearing as part of something bigger, all
    -- checked outside any handler so the bulk paths cost no subtransaction —
    -- same reasoning as `_broadcast_meeting_change` above, and needed here for
    -- more paths than that function has.
    --
    --   * the session is gone or trashed — the purge, or a hard delete;
    --   * the *folder* is gone — deleting one project cascades a link per
    --     session filed in it, and a hundred-session project would otherwise be
    --     a hundred trips through the handler and a hundred identical pokes,
    --     when the `folder_shares` cascade already sends the one message its
    --     audience needs;
    --   * the owner is gone — an account erasure reaches `meeting_labels` by
    --     three cascades at once (`meetings`, `labels`, and this table's own
    --     `user_id`), and which arrives first is a text sort over constraint
    --     names. Asking about the owner rather than about whichever parent won
    --     the race makes the answer the same on every machine.
    select m.user_id into v_owner
      from public.meetings m
     where m.id = v_row.meeting_id
       and m.deleted_at is null
       and exists (select 1 from auth.users u where u.id = m.user_id);
    if v_owner is null
       or not exists (select 1 from public.labels l where l.id = v_row.label_id) then
        return null;
    end if;

    begin
        for v_topic in
            select distinct case
                       when fs.team_id is not null then 'team:' || fs.team_id::text
                       else 'org:' || fs.org_id::text
                   end
              from public.folder_shares fs
             where fs.label_id = v_row.label_id
        loop
            perform public._notify_access_changed(v_topic);
        end loop;

        perform public._notify_access_changed('user:' || v_owner::text);
    exception when others then
        raise warning 'broadcast_filing_change failed: %', sqlerrm;
    end;
    return null;
end;
$$;

revoke all on function public._broadcast_filing_change() from public, anon, authenticated, service_role;

create trigger broadcast_access after insert or delete on public.meeting_labels
    for each row execute function public._broadcast_filing_change();
