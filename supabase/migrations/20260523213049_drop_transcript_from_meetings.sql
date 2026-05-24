-- Drop the `transcript` column from `meetings`. The full transcript is
-- legally a recording of all participants and storing it on the server
-- creates retention / discovery exposure we don't want to carry. We keep
-- the transcript in-memory during the meeting (it's the LLM's input for
-- summary generation) but it never lands in the database.
--
-- The summary is durable; the transcript is ephemeral.
--
-- This DROP is destructive — any transcripts already saved during the
-- short window between migration `20260523204132_meetings.sql` and this
-- one are deleted. Per the legal stance, that's the desired behaviour.
--
-- Issue #14 follow-up.

alter table public.meetings drop column if exists transcript;
