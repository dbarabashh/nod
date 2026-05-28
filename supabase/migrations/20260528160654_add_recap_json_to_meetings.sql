-- Structured recap (topics / decisions / actions / open_questions) emitted by
-- the summary LLM call. Nullable for backward compatibility — meetings
-- generated before this column existed keep working off the markdown in
-- `meetings.summary`, which is itself derived from this JSON for new rows.
alter table public.meetings
    add column recap_json jsonb null;
