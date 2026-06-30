-- Action items — first-class, per-user to-dos extracted from a meeting's recap.
-- Promotes action items from markdown-inside-`meetings.summary` to durable rows
-- so they can carry a persistent `done` state, be aggregated across meetings in
-- the History view, and (later) be deduped. Single-user product: there is no
-- owner/assignee model — every item is the user's own task. `deleted_at`
-- mirrors the `meetings` soft-delete pattern; rows also cascade-delete with
-- their meeting.

create table public.action_items (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    text        text        not null,
    -- Free-text deadline as stated in the meeting ("by Friday", "next week") —
    -- the recap captures it verbatim, not always a parseable date.
    deadline    text,
    -- Preserves the recap's emitted order within a meeting; created_at ties on
    -- bulk insert, so ordering keys off this instead.
    position    int         not null default 0,
    done        boolean     not null default false,
    done_at     timestamptz,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    deleted_at  timestamptz
);

-- Rendering a meeting's own list: its items, in recap order, excluding trash.
-- Unique on (meeting_id, position) so the recap-promotion insert is atomically
-- idempotent: the finalize-time save and a later lazy view backfill can race,
-- and the loser's batch fails wholesale instead of duplicating the checklist.
-- Scoped to live rows so a user-added task can reuse a trashed item's position.
create unique index action_items_meeting_idx
    on public.action_items (meeting_id, position)
    where deleted_at is null;

-- The History aggregate: the user's items, newest meeting first, open ones
-- first within that, excluding trash.
create index action_items_user_idx
    on public.action_items (user_id, done, created_at desc)
    where deleted_at is null;

alter table public.action_items enable row level security;

-- NOTE: the SELECT policy intentionally does NOT filter `deleted_at is null`.
-- Postgres checks an UPDATE's new row against the SELECT policy, so a soft-delete
-- (stamping `deleted_at`) would make the row fail this policy and raise a
-- "new row violates row-level security policy" error. Trashed rows are hidden in
-- the read queries instead (ActionItemStore adds `.is("deleted_at", nil)`).
create policy "users read own action_items"
    on public.action_items for select to authenticated
    using (auth.uid() = user_id);

create policy "users insert own action_items"
    on public.action_items for insert to authenticated
    with check (auth.uid() = user_id);

create policy "users update own action_items"
    on public.action_items for update to authenticated
    using (auth.uid() = user_id);

create policy "users delete own action_items"
    on public.action_items for delete to authenticated
    using (auth.uid() = user_id);
