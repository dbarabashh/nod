-- Ambient screen context: what was on screen, as text, so "Ask Nod" can answer
-- from more than meeting transcripts ("what was that ticket Leo moved?").
--
-- This is a deliberate widening of what Nod holds. Until now the only content
-- source was audio the user pressed record on; an observation is captured
-- without a per-item decision, so the table is built to be forgettable:
--
--   * `content` is TEXT read from the accessibility tree — never an image.
--     There is no screenshot to store, leak, or subpoena.
--   * `expires_at` is set on every row and a pg_cron job deletes past it, so
--     retention is bounded by default rather than by the user remembering to
--     prune. Meeting transcripts are kept until deleted; observations are not.
--   * `content_hash` + the unique index collapse the near-duplicates a polling
--     capture produces: a static screen must not become a thousand rows.
--   * `source_app` / `source_title` are kept so an answer can say where it saw
--     something, and so a user who excludes an app afterwards can find and
--     delete what was already captured from it.
--
-- Same per-user RLS and same eu-west-1 region as everything else. `on delete
-- cascade` from auth.users: this is derived context, not a legal record, so an
-- account erasure takes it.

create table public.screen_observations (
    id            uuid        primary key default gen_random_uuid(),
    user_id       uuid        not null references auth.users(id) on delete cascade,
    observed_at   timestamptz not null default now(),
    created_at    timestamptz not null default now(),
    -- Bundle identifier of the app the text came from, e.g. com.tinyspeck.slackmacgap.
    source_app    text        not null,
    -- Window title at capture time. Also what website exclusions match on.
    source_title  text        not null,
    -- The text itself. Capped client-side; a window dump is not a document.
    content       text        not null,
    -- SHA-256 of the normalised content, for the dedup index below.
    content_hash  text        not null,
    -- Bounded retention. The client sets this; the cron job enforces it.
    expires_at    timestamptz not null
);

-- One row per distinct screen state per app. A repeated capture of an unchanged
-- window updates `observed_at` instead of inserting.
create unique index screen_observations_dedup_idx
    on public.screen_observations (user_id, source_app, content_hash);

create index screen_observations_recent_idx
    on public.screen_observations (user_id, observed_at desc);

create index screen_observations_expiry_idx
    on public.screen_observations (expires_at);

alter table public.screen_observations enable row level security;

create policy "users insert own screen observations"
    on public.screen_observations
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users read own screen observations"
    on public.screen_observations
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users update own screen observations"
    on public.screen_observations
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Deleting what Nod saw must be as easy as it was to capture.
create policy "users delete own screen observations"
    on public.screen_observations
    for delete
    to authenticated
    using (auth.uid() = user_id);

-- Enforce retention server-side, so an app that never launches again still
-- stops holding context.
select cron.schedule(
    'purge-expired-screen-observations',
    '17 4 * * *',
    $$delete from public.screen_observations where expires_at < now()$$
);
