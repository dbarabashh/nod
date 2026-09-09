-- `integration_connections` gets a surrogate key and a team.
--
-- The primary key was `(user_id, provider)`, which is the natural key and the
-- wrong one to make primary, for two reasons that arrived from different
-- directions:
--
--   * Linking an enterprise identity provider mints a *second* account for an
--     address that already signed up — Supabase refuses to link SSO identities
--     to existing users on purpose — so the two have to be merged, and a merge
--     repoints `user_id` across every table carrying it. A composite key turns
--     "both accounts had Linear connected" into a constraint violation that
--     aborts the merge, which is the case a merge exists for.
--   * A connection needs to say which team's work it is for, and a key made of
--     the columns that identify a row is a key that has to be rebuilt every time
--     the row learns something new.
--
-- The uniqueness itself is right and is kept, as an index rather than a key.
--
-- `team_id` scopes the connection, it does not share it. The OAuth credential
-- stays Nango's and stays the connecting person's; what this records is which
-- team's Linear this is, so the chat reaches for the right workspace when the
-- person is working in that team's context. Nobody acts in anyone else's name
-- because of a value in this column, and nothing here grants a teammate access
-- to it.

alter table public.integration_connections
    drop constraint integration_connections_pkey;

alter table public.integration_connections
    add column id uuid not null default gen_random_uuid();

alter table public.integration_connections
    add constraint integration_connections_pkey primary key (id);

create unique index integration_connections_owner_provider_idx
    on public.integration_connections (user_id, provider);

alter table public.integration_connections
    add column team_id uuid references public.teams(id) on delete set null;

create index integration_connections_team_idx
    on public.integration_connections (team_id) where team_id is not null;
