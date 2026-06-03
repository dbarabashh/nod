-- Rollback for 20260602120100_add_meeting_kind.sql
-- Drops the kind column. Existing meetings are unaffected — they simply lose
-- the kind tag and behave as plain meetings again.

alter table public.meetings
    drop column if exists kind;
