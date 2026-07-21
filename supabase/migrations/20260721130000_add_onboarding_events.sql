-- Funnel log for the screens between sign-in and the first recording.
--
-- Onboarding progress lives in UserDefaults only (`OnboardingState`), so the
-- steps leave no server-side trace at all. The two rows a new user does
-- produce — `user_devices` and `profiles` — are both written automatically the
-- instant sign-in succeeds, and the next signal is `consent_acknowledgements`,
-- which is written on the first Start-meeting click. Everything in between
-- (welcome, profile, permissions, the Screen Recording quit-and-relaunch,
-- tutorial) was invisible: a user who abandoned at the TCC prompt looked
-- identical to one who never launched the app. On 2026-07-21, six of seventeen
-- signups in the prior two weeks had a bound device and zero meetings with no
-- way to tell where they stopped.
--
-- First-party only — no analytics SDK, same per-user RLS as every other table,
-- same eu-west-1 region. `on delete cascade` because this is product
-- telemetry, not a legal record: an account erasure takes it with it (unlike
-- `consent_acknowledgements`, which deliberately outlives the user).

create table public.onboarding_events (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    -- e.g. step_shown, permission_granted, relaunch_prompted. Deliberately not
    -- a check constraint or enum: adding a funnel event should be a client
    -- release, not a migration.
    event       text        not null,
    -- Onboarding step the event belongs to, when it maps to one.
    step        text,
    -- Event-specific qualifier — which permission, which failure.
    detail      text,
    app_version text        not null
);

create index onboarding_events_user_id_idx
    on public.onboarding_events (user_id, created_at desc);

-- Funnel queries scan by event across all users, not by user.
create index onboarding_events_event_idx
    on public.onboarding_events (event, created_at desc);

alter table public.onboarding_events enable row level security;

create policy "users insert own onboarding events"
    on public.onboarding_events
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users read own onboarding events"
    on public.onboarding_events
    for select
    to authenticated
    using (auth.uid() = user_id);
