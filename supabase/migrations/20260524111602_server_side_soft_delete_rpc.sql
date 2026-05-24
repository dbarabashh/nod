-- Server-side `deleted_at` stamping. The previous client-side path sent
-- `Date()` from the Mac's wall-clock — if the device clock is skewed (corp
-- MDM, dead CMOS, dual-boot drift, …), the pg_cron purge job's condition
-- `deleted_at < now() - interval '30 days'` evaluates against server time
-- and can purge a row well before the intended 30-day grace window.
--
-- This RPC stamps `deleted_at = now()` server-side so the timestamp is
-- always trustworthy. Runs as the caller (security invoker) so the
-- existing RLS UPDATE policy still gates ownership.
--
-- Issue #16 follow-up.

create or replace function public.soft_delete_meeting(meeting_id uuid)
returns void
language sql
security invoker
as $$
    update public.meetings
    set deleted_at = now()
    where id = meeting_id
      and user_id = auth.uid()
      and deleted_at is null;
$$;

-- Mirror for restore — keeps the symmetry tidy and lets us evolve both
-- sides server-side later (e.g. add an audit log of soft-delete events
-- in a follow-up without touching the client).
create or replace function public.restore_meeting(meeting_id uuid)
returns void
language sql
security invoker
as $$
    update public.meetings
    set deleted_at = null
    where id = meeting_id
      and user_id = auth.uid()
      and deleted_at is not null;
$$;
