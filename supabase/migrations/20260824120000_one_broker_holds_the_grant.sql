-- The column named the broker, so changing brokers renamed the column.
--
-- `nango_connection_id` held a pointer into one vendor's connection store. What
-- the row has always meant is "the account the broker holds for this person and
-- this product", and that outlives any particular broker — so the column now
-- says that instead, and the vendor's name appears nowhere in the schema.
--
-- No compatibility window and no dual-write. `integration_connections` has never
-- existed in production (integrations are a `develop`-only feature so far), so
-- there is no released consumer to keep working and nothing to migrate
-- gradually. Should that stop being true before this ships, this file has to
-- become an expand/migrate/contract pair instead.

alter table public.integration_connections
    rename column nango_connection_id to broker_account_id;

alter index public.integration_connections_nango_idx
    rename to integration_connections_broker_account_idx;

-- Every id in the table addresses a connection at the old broker, which we no
-- longer talk to. Leaving them live would mean a Settings row that reads
-- "Connected" over a grant nothing can reach: the person would only find out at
-- the moment they asked Nod to look something up mid-meeting. Revoking says the
-- true thing — reconnect once, and the trigger on this table clears whatever
-- came with the old grant.
update public.integration_connections
   set revoked_at = now()
 where revoked_at is null;
