-- The consent log so far recorded that a text was acknowledged. The
-- diagnostics question has two switches, and "asked on this date" is only
-- half an answer without which way each was set. Nullable and unread by the
-- app: the row is evidence, not state.

alter table public.consent_acknowledgements
    add column if not exists details jsonb;

comment on column public.consent_acknowledgements.details is
    'What was chosen where the acknowledgement carries choices, e.g. {"crash_reports": true, "usage_events": false}. Null for a plain acknowledgement.';
