-- Diarized speaker index per transcript chunk (issue: speaker diarization).
-- On-device clustering of the system-audio (`them`) stream assigns each
-- utterance a 0-based speaker index; the mic (`me`) stream is always the
-- local user, so its rows stay null. Nullable because existing rows predate
-- diarization and because diarization is best-effort (absent if the embedding
-- model fails to load). The detail view renders "Them 1/2/…" from this.
alter table public.meeting_transcripts
    add column speaker smallint;
