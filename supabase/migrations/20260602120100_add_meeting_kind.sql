-- Session kind — Nod records more than meetings now. A row can be a
-- two-party `meeting` (mic + system audio), a solo `voice_note` (mic only),
-- or `media` the user is listening to (system audio only). The kind drives
-- which audio streams open and which recap framing the LLM uses.
--
-- Additive + backward-compatible: existing rows default to 'meeting', the
-- column is NOT NULL with a default, and the table keeps its name. Nothing
-- about the meetings/transcripts data changes.

alter table public.meetings
    add column kind text not null default 'meeting'
    check (kind in ('meeting', 'voice_note', 'media'));
