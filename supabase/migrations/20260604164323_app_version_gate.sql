-- App version gate (#17-adjacent): lets us require or recommend a client
-- update from the server, so a backend change that breaks old builds can be
-- followed by raising `minimum_build` — no client ship needed. Two thresholds:
-- below `minimum_build` the client hard-gates ("update to keep using Nod");
-- below `recommended_build` it shows a dismissible "new version" nudge. We
-- compare CFBundleVersion (a monotonic integer) rather than the marketing
-- string, so the check is `client_build < minimum_build` — no semver parsing.

-- Single-row config. The `singleton` check keeps it to one row so the client
-- can read it with `.limit(1)` and never reconcile conflicting rows.
create table public.app_config (
    singleton         boolean     primary key default true,
    minimum_build     integer     not null default 0,
    recommended_build integer     not null default 0,
    platform          text        not null default 'macos',
    update_message    text,
    updated_at        timestamptz not null default now(),
    constraint app_config_singleton check (singleton)
);

-- Seed with non-gating defaults: nothing is required (0), recommend the
-- current build. Raise these from the dashboard when a release ships, and
-- only raise `minimum_build` once a truly breaking migration is live.
insert into public.app_config (singleton, minimum_build, recommended_build)
values (true, 0, 18);

alter table public.app_config enable row level security;

-- Read-only to every signed-in client; writes happen via the dashboard /
-- service role only (no client policy for insert/update/delete).
create policy "authenticated read app_config"
    on public.app_config
    for select
    to authenticated
    using (true);

-- Version visibility: stamp the client's build onto its profile row on each
-- authenticated proxy call. Answers "what version is this user on?" from the
-- DB without an analytics SDK, and gives a last-seen heartbeat alongside the
-- build. Supabase Auth already tracks last_sign_in_at; this adds the version.
alter table public.profiles add column app_build    integer;
alter table public.profiles add column app_version  text;
alter table public.profiles add column os_version   text;
alter table public.profiles add column last_seen_at timestamptz;
