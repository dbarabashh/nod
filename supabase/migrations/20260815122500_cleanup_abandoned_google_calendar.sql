-- Removing the abandoned direct-to-Google calendar overlay.
--
-- The `google-calendar` branch was applied to the sandbox and then closed
-- without ever being recorded in `supabase_migrations.schema_migrations`. The
-- objects stayed. This is the same shape of drift as the NOD-31 workspace
-- overlay cleaned in `20260814104956`, and it gets the same treatment: prod
-- never had any of it (verified — zero calendar objects there), every table
-- here is empty, and the replacement in the next migration reads a calendar
-- through Nango instead.
--
-- `google_calendar_connections.refresh_token` is the reason this is a deletion
-- rather than a rename. That column is a Google refresh token — a credential
-- that opens a person's entire calendar — sitting in our own database. Routing
-- through Nango exists precisely so no such column has to.
--
-- The action-item link columns go too. They were the branch's reconciliation
-- feature, nothing writes them, and if that idea returns it should arrive with
-- its own migration and its own reasoning rather than as a leftover.

-- The policies are not dropped by name. `drop policy if exists` guards the
-- policy and not the table, so naming one on a table that never existed raises
-- 42P01 — which is every instance except the sandbox this drift is on, prod and
-- a fresh branch instance included. Dropping the table takes its policies with
-- it, so there is nothing the four statements did that these two do not.

alter table public.action_items
    drop column if exists calendar_event_id,
    drop column if exists calendar_link_state;

drop table if exists public.calendar_events;
drop table if exists public.google_calendar_connections;
