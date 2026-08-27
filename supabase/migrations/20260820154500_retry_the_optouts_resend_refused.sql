-- Every opt-out queued since 2026-08-12 died at the provider and stayed dead.
--
-- The worker patched contact topics as `{"topics": [...]}`, but Resend's
-- PATCH /contacts/{id_or_email}/topics validates a bare array and answered 422
-- ("The `` field must be an `array`." — the unnamed field is the request root).
-- A 422 is not retryable, so `complete_resend_contact_sync` parked every row in
-- `failed`, and `claim_resend_contact_sync` only ever claims `queued`. Supabase
-- recorded each withdrawal correctly; Resend was never told.
--
-- The worker now sends the array. Nothing else will look at these rows again, so
-- they have to go back in the queue here. `resend_contact_sync_guard` still runs
-- before each provider call, so anyone who re-subscribed in the meantime wins.

update public.resend_contact_sync
   set status = 'queued',
       attempts = 0,
       available_at = now(),
       last_error = null,
       updated_at = now()
 where status = 'failed'
   and last_error like '%status=422%'
   and last_error like '%validation_error%';
