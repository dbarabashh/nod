-- Which app the token belongs to.
--
-- `environment` says which APNs gateway to use; it does not say what to put in
-- `apns-topic`, and APNs rejects a push whose topic is not the app's bundle id.
-- Those two are not the same axis here: the Sandbox configuration ships as
-- `nod.nod-ios.sandbox` through the PRODUCTION gateway (TestFlight), while a
-- Debug build is `nod.nod-ios` through the sandbox one. Deriving one from the
-- other would silently misroute exactly the builds we test with.
--
-- Added rather than backfilled: the table landed minutes ago and holds no rows.
alter table public.push_tokens
    add column bundle_id text not null default 'nod.nod-ios';

alter table public.push_tokens
    alter column bundle_id drop default;
