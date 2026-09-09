-- The table refuses what the RPC accepts.
--
-- `product_events` has two gates. `20260811154500` turned the RPC's copy of
-- the allow-list into `_client_product_events()` so the two client-side lists
-- could not drift; the table's own CHECK constraint stayed a literal, last
-- rewritten on 2026-08-11. `20260830211900` and `20260906214122` then widened
-- the function by twenty-four events and touched the constraint not at all.
--
-- The RPC validates each event against the function, passes, and inserts —
-- and the insert violates `product_events_event_check`. That exception is
-- not caught per item the way a bad event is, so the whole call fails, the
-- client's flush fails, and every queued event on that Mac — the valid ones
-- included — is retried on every flush and never lands. The develop branch
-- has been logging `product analytics flush failed` on every cycle.
--
-- The constraint now derives from the same function, plus the three events
-- only edge functions write from provider truth. Widening the function widens
-- the table; a client still cannot forge a server event, because the RPC's
-- own check is the client list alone.

create or replace function public._server_product_events()
returns text[]
language sql
immutable
set search_path = ''
as $$
    select array['checkout_started', 'topup_checkout_started', 'topup_purchased']::text[];
$$;

revoke all on function public._server_product_events() from public, anon, authenticated;
grant execute on function public._server_product_events() to service_role;

alter table public.product_events
    drop constraint product_events_event_check;

alter table public.product_events
    add constraint product_events_event_check
    check (event = any (public._client_product_events() || public._server_product_events()));
