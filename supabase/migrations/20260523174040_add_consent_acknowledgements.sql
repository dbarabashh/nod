-- Recording-consent audit log. Each row records one user clicking
-- "Acknowledge & Start" on the disclaimer modal (Nod/Consent/*). Required
-- because UserDefaults-only persistence has no audit trail — if a meeting
-- participant later disputes consent, this table is the legal artefact.
--
-- Issue #4 — https://github.com/dbarabashh/Nod/issues/4

create table public.consent_acknowledgements (
    id                  uuid        primary key default gen_random_uuid(),
    -- Nullable + `on delete set null` so the audit row outlives the auth
    -- user. If a user is deleted (GDPR request, account removal) we keep
    -- the immutable acknowledgement record for legal review; the row just
    -- becomes orphaned and only visible to service-role admins.
    user_id             uuid        references auth.users(id) on delete set null,
    accepted_at         timestamptz not null default now(),
    -- Stable identifier for the disclaimer text the user actually agreed to.
    -- Bumped whenever ConsentStrings copy changes materially.
    disclaimer_version  text        not null,
    -- BCP-47 language code of the localised copy the user saw.
    language_code       text        not null check (language_code ~ '^[a-z]{2}(-[A-Z]{2})?$'),
    -- CFBundleShortVersionString of the client that wrote the row.
    app_version         text        not null
);

create index consent_acknowledgements_user_id_idx
    on public.consent_acknowledgements (user_id, accepted_at desc);

alter table public.consent_acknowledgements enable row level security;

-- A user can only write rows attributed to themselves.
create policy "users insert own consent rows"
    on public.consent_acknowledgements
    for insert
    to authenticated
    with check (auth.uid() = user_id);

-- A user can only read their own consent rows. Server-side audits use the
-- service role and bypass RLS.
create policy "users read own consent rows"
    on public.consent_acknowledgements
    for select
    to authenticated
    using (auth.uid() = user_id);
