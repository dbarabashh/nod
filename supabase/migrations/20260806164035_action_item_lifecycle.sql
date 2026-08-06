-- Action items become the running state of a meeting rather than a one-shot
-- dump written when the recap lands.
--
-- Today every row is created once, at finalize, from `MeetingRecap.Action`, and
-- the only thing that ever happens to it afterwards is `done` or `deleted_at`.
-- That is enough for "here is your checklist" and not enough for what a meeting
-- actually does to its own decisions: a task named at 14:03 gets an owner at
-- 14:07, a deadline at 14:12, and is called off at 14:20. The columns below are
-- what it takes to record that as it happens instead of flattening it into one
-- line at the end.
--
-- `kind` widens the table past tasks, because the live pass hears four other
-- things worth keeping and they have nowhere to go today.
--
-- `status` is the lifecycle, and it is deliberately orthogonal to `done`:
-- `done` is the user's checkbox on a real task, `status` is whether the item is
-- a real task at all yet. A live pass is allowed to be wrong, so what it finds
-- lands as `proposed` and stays out of the user's counts until the recap
-- corroborates it or the user acts on it. Without that split one bad minute of
-- transcription inflates "open commitments" on the Home screen.
--
-- `revision_of` is the chain the product is actually about: "we agreed X, then
-- we agreed Y instead". The replacement points back at what it replaced, and
-- the replaced row is marked `superseded` rather than rewritten in place —
-- rewriting loses exactly the history worth showing.
--
-- `evidence_idx` anchors an item to the transcript entry that produced it
-- (`meeting_transcripts.idx`, unique per meeting). It is the cheapest column
-- here and the only one that cannot be backfilled: by the time anyone wants to
-- ask "why does this exist, who said it", the moment is gone. It is also what a
-- future export needs — a ticket created from a meeting has to be able to point
-- at the sentence that caused it.
--
-- Deliberately NOT added:
--   * an owner/assignee column. This stays a single-user product: every item is
--     the user's own, and "ask Sam" lives inside `text`. An action item with an
--     owner is a different product — it means inferring, and then publishing, a
--     claim about somebody who is not the user.
--   * `external_ref` (provider, id, url) for Slack/Jira/Linear. There is no
--     reader for it, `status` already has room for an `exported` value, and a
--     jsonb column is cheap to add the day the first integration lands. Unlike
--     `evidence_idx`, nothing is lost by waiting.

alter table public.action_items
    add column kind text not null default 'action'
        check (kind in ('action', 'decision', 'question', 'risk', 'follow_up')),
    add column status text not null default 'confirmed'
        check (status in ('proposed', 'confirmed', 'superseded', 'dropped')),
    add column source text not null default 'recap'
        check (source in ('recap', 'live', 'user')),
    add column revision_of uuid references public.action_items(id) on delete set null,
    add column evidence_idx integer;

-- Existing rows are recap-derived and already visible to the user, so the
-- defaults above are their correct backfill: `action` / `confirmed` / `recap`.

-- `position` was the recap's emitted order, and the unique index made that
-- order load-bearing. A live pass has no such order — it appends as the meeting
-- goes and re-orders nothing — so its rows carry no position at all, and the
-- index has to stop demanding one.
--
-- The `default 0` has to go with the NOT NULL, and dropping only the latter is
-- a trap: the client omits the column entirely when it has no position, so the
-- default would quietly fill in 0 and every live row would collide with the
-- recap's first action in the unique index below — taking the whole insert
-- down with it. Nothing relies on the default; every writer that has an order
-- states it.
alter table public.action_items
    alter column position drop not null,
    alter column position drop default;

drop index if exists action_items_meeting_idx;

create unique index action_items_meeting_idx
    on public.action_items (meeting_id, position)
    where deleted_at is null and position is not null;

-- The live pass's own read: this meeting's items, whatever state they are in,
-- so a new finding can be checked against what is already known without pulling
-- the user's whole history.
create index action_items_meeting_status_idx
    on public.action_items (meeting_id, status)
    where deleted_at is null;
