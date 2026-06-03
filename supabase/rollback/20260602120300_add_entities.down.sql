-- Rollback for 20260602120300_add_entities.sql
-- Drops the junction first (FK), then the entities table. meetings /
-- transcripts are untouched.
-- WARNING: destroys all extracted entity links.

drop table if exists public.meeting_entities cascade;
drop table if exists public.entities cascade;
