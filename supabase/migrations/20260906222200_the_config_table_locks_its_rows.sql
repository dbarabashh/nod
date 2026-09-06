-- The one table in `private` without row security. Nothing but postgres and
-- the auth admin can reach the schema, so this is a second lock on a locked
-- door — but the token hook runs as `supabase_auth_admin` with SECURITY
-- INVOKER, and that role does not bypass RLS, so it needs its own policy or
-- every sign-in that carries a connector client_id fails at the hook. The
-- founder-connector helpers read the table as postgres and are unaffected.

alter table private.connector_oauth_config enable row level security;

create policy "auth admin reads connector config"
    on private.connector_oauth_config
    for select
    to supabase_auth_admin
    using (true);
