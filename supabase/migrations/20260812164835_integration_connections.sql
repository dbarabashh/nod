-- Outbound integrations: the third-party accounts a user linked so Nod can act
-- in them — the first being an action item becoming a Linear issue.
--
-- Deliberately NOT `public.connections`. That table is the *inbound* direction:
-- personal access tokens that let the user's own AI client read their meetings.
-- Same word, opposite arrow; sharing the name would guarantee a wrong join.
--
-- No credential ever lands here. Nango holds the OAuth tokens and refreshes
-- them (Linear access tokens expire after 24h); this row is a pointer plus the
-- state Settings needs to render "Connected".
create table public.integration_connections (
    user_id             uuid        not null references auth.users(id) on delete cascade,
    provider            text        not null check (provider in ('linear')),
    nango_connection_id text        not null,
    connected_at        timestamptz not null default now(),
    revoked_at          timestamptz,
    primary key (user_id, provider)
);

-- One Nango connection maps to exactly one row, so a webhook that arrives for a
-- connection we already replaced cannot resurrect a second link.
create unique index integration_connections_nango_idx
    on public.integration_connections (nango_connection_id);

alter table public.integration_connections enable row level security;

-- Owners read their own links; nobody writes through the client. The
-- authoritative event is Nango's `auth`/`creation` webhook, handled by
-- `nango-webhook` under the service role — an authenticated user must not be
-- able to claim a connection id that was issued to someone else.
create policy "owners read own integration connections"
    on public.integration_connections
    for select
    to authenticated
    using (auth.uid() = user_id);

grant select, insert, update on table public.integration_connections to service_role;
