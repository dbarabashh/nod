-- Open loops: a promise, a question or a decision is a thing with a life, not a
-- checkbox.
--
-- `action_items` already carries the vocabulary — `kind` tells a commitment from
-- a question, `revision_of` chains supersession, `evidence_idx` points at the
-- utterance that produced it. What it has never carried is what became of the
-- thing: `done` is one boolean somebody has to tick, and 431 rows on this
-- account are sitting open because nobody ticks it.
--
-- Expand only. `done` keeps its meaning and keeps working for every released
-- client; `loop_state` is derived from it on the way in and derives it on the
-- way out, so a build that has never heard of this column reads and writes the
-- same rows correctly. Nothing is dropped and no check is narrowed.

-- The lifecycle. Deliberately more than open/closed, because "somebody merged
-- the PR" and "the person who asked said thanks" are different amounts of
-- knowing, and collapsing them is how a system closes something that is not
-- done.
alter table public.action_items
    add column if not exists loop_state text not null default 'open';

do $$ begin
    alter table public.action_items
        add constraint action_items_loop_state_check
        check (loop_state in (
            'open',           -- nobody has moved on it
            'in_progress',    -- somebody has, and said so
            'probably_done',  -- evidence says done; nobody confirmed
            'confirmed',      -- done, and we can say why we believe it
            'blocked',        -- waiting on something named
            'cancelled',      -- it will not happen, and that is settled
            'superseded'      -- another item replaced it
        ));
exception when duplicate_object then null; end $$;

-- Existing rows get the state their old columns already implied. `done` is the
-- strongest signal we have and it was set by a person, so it lands on
-- `confirmed` rather than `probably_done`.
update public.action_items
set loop_state = case
    when done then 'confirmed'
    when status = 'superseded' then 'superseded'
    when status = 'dropped' then 'cancelled'
    else 'open'
end
where loop_state = 'open';

-- Who owes it and who is waiting. Both nullable: most items name nobody, and a
-- guess about who promised something is worse than an absence.
alter table public.action_items
    add column if not exists owner_person_id uuid references public.people(id) on delete set null,
    add column if not exists counterparty_person_id uuid references public.people(id) on delete set null;

-- The utterances this came out of, not one of them.
--
-- `evidence_idx` stays and stays authoritative for old clients. This is the set
-- form: a commitment is usually stated across two or three turns, and the
-- annotation literature settles on sets of utterances rather than a time range
-- because a person can point at utterances and cannot point at milliseconds.
--
-- `evidence_quote` is the re-anchor: transcript indexes move when a meeting is
-- re-transcribed, and a stored quote survives that where an index does not.
alter table public.action_items
    add column if not exists evidence_idxs int[],
    add column if not exists evidence_quote text;

update public.action_items
set evidence_idxs = array[evidence_idx]
where evidence_idx is not null and evidence_idxs is null;

-- Every move, with what moved it.
--
-- The transitions are the product: "probably done because PR #912 merged and
-- Linear went Done" is the sentence this table exists to be able to say. A
-- state without its reason is a state nobody can argue with, and this one has
-- to be arguable — it will be wrong sometimes.
create table if not exists public.action_item_transitions (
    id              uuid        primary key default gen_random_uuid(),
    action_item_id  uuid        not null references public.action_items(id) on delete cascade,
    user_id         uuid        not null references auth.users(id) on delete cascade,
    from_state      text,
    to_state        text        not null,
    -- What moved it. `system` is our own inference and the only one that may be
    -- wrong in a way the person did not choose.
    actor           text        not null check (actor in ('user', 'system', 'external')),
    -- Free-form and human-readable, because it is shown: "PR #912 merged".
    reason          text,
    -- What it was read from. Named provider + key so the claim can be reopened
    -- and rechecked, not just displayed.
    evidence        jsonb       not null default '[]'::jsonb,
    confidence      numeric(3,2) check (confidence is null or (confidence >= 0 and confidence <= 1)),
    -- Which version of the resolver decided. A rule that turns out to close
    -- things wrongly has to be findable after the fact.
    resolver        text,
    at              timestamptz not null default now()
);

create index if not exists action_item_transitions_item_idx
    on public.action_item_transitions (action_item_id, at desc);
create index if not exists action_item_transitions_user_idx
    on public.action_item_transitions (user_id, at desc);

alter table public.action_item_transitions enable row level security;

create policy "users read own transitions"
    on public.action_item_transitions for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own transitions"
    on public.action_item_transitions for insert to authenticated
    with check (auth.uid() = user_id);

-- Old clients keep working, in both directions.
--
-- A build that has never heard of `loop_state` writes `done` and expects that to
-- mean closed; a build that writes `loop_state` expects `done` to follow. This
-- keeps the two coherent without either side knowing about the other, which is
-- the whole of the mixed-version contract until the older builds are gone.
create or replace function public.action_items_sync_loop_state()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'UPDATE' then
        -- The person ticked the box: that is a confirmation, whatever we thought.
        if new.done is distinct from old.done then
            new.loop_state := case when new.done then 'confirmed' else 'open' end;
        -- We moved the state: `done` follows, so an old client still reads it right.
        elsif new.loop_state is distinct from old.loop_state then
            new.done := new.loop_state = 'confirmed';
            if new.done and new.done_at is null then
                new.done_at := now();
            end if;
        end if;
    elsif tg_op = 'INSERT' and new.done and new.loop_state = 'open' then
        new.loop_state := 'confirmed';
    end if;
    return new;
end $$;

drop trigger if exists action_items_loop_state on public.action_items;
create trigger action_items_loop_state
    before insert or update on public.action_items
    for each row execute function public.action_items_sync_loop_state();

-- What is actually open, oldest first. The list this whole thing exists to draw.
create index if not exists action_items_open_loops_idx
    on public.action_items (user_id, loop_state, created_at)
    where deleted_at is null and status = 'confirmed';
