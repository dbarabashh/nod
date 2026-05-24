-- Meetings table — the durable record of every completed meeting.
-- Each row owns its summary + transcript, scoped to the user who recorded
-- it via RLS. `deleted_at` is the soft-delete column wired up by #16; this
-- migration just reserves the column and excludes deleted rows from the
-- read policy + the lookup index.
--
-- Issue #14 — https://github.com/dbarabashh/Nod/issues/14

create table public.meetings (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    started_at  timestamptz not null,
    ended_at    timestamptz not null,
    title       text,
    summary     text        not null,
    transcript  text        not null,
    language    text        not null default 'en',
    deleted_at  timestamptz
);

-- Listing is "your meetings, newest first, excluding the trash" — index
-- matches that exact query shape so we don't pay for a sort + filter scan.
create index meetings_user_started_idx
    on public.meetings (user_id, started_at desc)
    where deleted_at is null;

alter table public.meetings enable row level security;

create policy "users read own meetings"
    on public.meetings
    for select
    to authenticated
    using (auth.uid() = user_id and deleted_at is null);

create policy "users insert own meetings"
    on public.meetings
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users update own meetings"
    on public.meetings
    for update
    to authenticated
    using (auth.uid() = user_id);

create policy "users delete own meetings"
    on public.meetings
    for delete
    to authenticated
    using (auth.uid() = user_id);
