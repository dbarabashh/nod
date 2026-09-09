-- A connection is no longer only to a product Nod has adapters for.
--
-- The catalogue shows every product the broker can authorize, and the check
-- constraint listing our three made "Connect" a button we could only offer on
-- three rows. Authorizing is worth having on its own: it is the grant, made
-- once, that a later release can start acting in — and it is a far better
-- signal about what to build next than any list of requests.
--
-- The column now holds either one of our provider names or the broker's own app
-- slug. Both are stable identifiers for the same thing (a product), and
-- `registry.ts` is what decides whether Nod can act in one — `hasActions`
-- already refuses to address a provider it has no handlers for, so an
-- unadapted connection is inert rather than half-working.
--
-- Deploy order: this before the functions. A released `integration-reconcile`
-- writes only the three names, which this still accepts, so the old function
-- keeps working against the new constraint and the order is not load-bearing in
-- the other direction.

alter table public.integration_connections
    drop constraint integration_connections_provider_check;

-- Not unconstrained: the value reaches a URL and a `Provider-Config-Key`, and
-- the shape both the broker's slugs and our own names share is narrow enough to
-- keep anything else out.
alter table public.integration_connections
    add constraint integration_connections_provider_check
    check (provider ~ '^[a-z0-9][a-z0-9_-]{0,62}$');
