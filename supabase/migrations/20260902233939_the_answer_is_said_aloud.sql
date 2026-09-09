-- A spoken answer is a usage event of its own kind. Recorded so the spend on
-- the voice is visible beside chat and transcription, and so the allowance
-- sums — which name their kinds — are not touched by it.

alter table public.usage_events drop constraint usage_events_kind_check;
alter table public.usage_events add constraint usage_events_kind_check
    check (kind in ('chat', 'transcribe', 'embed', 'speak'));
