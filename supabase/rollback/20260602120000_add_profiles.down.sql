-- Rollback for 20260602120000_add_profiles.sql
-- Drops the profiles table and its policies. `meetings` / `meeting_transcripts`
-- are untouched — profiles is a standalone additive table.
-- WARNING: destroys every user's saved profile content.

drop table if exists public.profiles cascade;
