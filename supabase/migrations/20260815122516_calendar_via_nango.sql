-- Reading a calendar, through the same broker that already writes to Linear.
--
-- The `google-calendar` branch built this against Google directly, with our own
-- OAuth client and our own refresh-token column. That work is not being merged.
-- Nango already holds the authorization for every tool the user connects, and a
-- second credential store — one we hold ourselves, for the one provider whose
-- token unlocks a person's whole day — is the wrong asymmetry to introduce for
-- the sake of avoiding one row in a check constraint.
--
-- Two departures from that branch, both load-bearing:
--
--   * Provider-agnostic. `external_event_id` and a `provider` column rather than
--     `google_event_id`, because Nango's calendar catalogue is not only Google
--     and the second one must not need a second table.
--
--   * `ical_uid`. The branch stored `event.id`, which Google assigns per copy of
--     an event: the organizer's copy and each attendee's copy of the same
--     meeting carry different ids. Matching on it would have found no pair of
--     colleagues in the same meeting ever. `iCalUID` is the RFC 5545 identity
--     and is shared across every copy — it is the only field here that can
--     answer "are you and I looking at the same meeting", which is the entire
--     reason the calendar is being read at all.
--
-- Events stay private to the person whose calendar they came from. A colleague
-- never reads this table; what crosses between people is the meeting, and only
-- inside an organization they share.

alter table public.integration_connections
    drop constraint integration_connections_provider_check;

alter table public.integration_connections
    add constraint integration_connections_provider_check
    check (provider in ('linear', 'google-calendar'));

create table public.calendar_events (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references auth.users(id) on delete cascade,
    provider          text not null default 'google-calendar'
                          check (provider in ('google-calendar')),
    calendar_id       text not null,
    external_event_id text not null,
    ical_uid          text,
    title             text,
    conference_url    text,
    starts_at         timestamptz not null,
    ends_at           timestamptz,
    organizer_email   text,
    attendees         jsonb not null default '[]'::jsonb,
    is_cancelled      boolean not null default false,
    etag              text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

-- The sync's upsert key. Per calendar rather than per user alone: the same event
-- legitimately appears in a primary and a shared calendar, and collapsing those
-- would make each pass overwrite the other's copy.
create unique index calendar_events_external_id_idx
    on public.calendar_events (user_id, calendar_id, external_event_id);

-- The "what is starting soon" read, which is every read the app makes.
create index calendar_events_upcoming_idx
    on public.calendar_events (user_id, starts_at);

-- Matching goes the other way — from an identity to whoever has it on their
-- calendar — so it needs its own index and gets one only where the identity is
-- actually present.
create index calendar_events_ical_uid_idx
    on public.calendar_events (ical_uid) where ical_uid is not null;

alter table public.calendar_events enable row level security;

-- Read and delete only, deliberately. The calendar is the provider's copy of the
-- truth and the sync writes it with the service role; a client edit would be
-- silently undone on the next pass, which is worse than not being offered.
create policy "users read own calendar events"
    on public.calendar_events
    for select to authenticated
    using ((select auth.uid()) = user_id);

create policy "users delete own calendar events"
    on public.calendar_events
    for delete to authenticated
    using ((select auth.uid()) = user_id);

-- When we last looked, and what went wrong if anything did.
--
-- No sync token, deliberately. Google's incremental sync forbids changing the
-- time window between calls, so a token and a bounded window cannot both exist —
-- and the window is the more valuable of the two. It caps how much of somebody's
-- calendar is ever in our database, and it makes deletion fall out for free:
-- what the provider does not return for a window it was asked about is gone. A
-- token would save quota we are nowhere near spending.
create table public.calendar_sync_state (
    user_id       uuid not null references auth.users(id) on delete cascade,
    provider      text not null check (provider in ('google-calendar')),
    calendar_id   text not null,
    synced_at     timestamptz,
    last_error    text,
    primary key (user_id, provider, calendar_id)
);

alter table public.calendar_sync_state enable row level security;

-- Readable so the app can say when it last looked and why it stopped. Never
-- writable: a client that could clear `sync_token` could force a full re-read of
-- someone's calendar on demand.
create policy "users read own calendar sync state"
    on public.calendar_sync_state
    for select to authenticated
    using ((select auth.uid()) = user_id);

-- The sweep only maintains its own window, so a meeting that falls out the back
-- of it would otherwise stay forever. Someone's past year of meeting titles is
-- not something to keep by omission.
select cron.schedule(
    'purge-past-calendar-events',
    '31 4 * * *',
    $$delete from public.calendar_events where coalesce(ends_at, starts_at) < now() - interval '7 days'$$
);
