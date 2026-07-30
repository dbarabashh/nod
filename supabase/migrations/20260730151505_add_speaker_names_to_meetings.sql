-- Names for the diarized speaker clusters of one meeting, keyed by the cluster
-- number the transcript rows carry (`meeting_transcripts.speaker`):
--   {"1": "Eric Johnson", "2": "Lily"}
--
-- Only clusters the transcript itself identifies unambiguously get an entry, so
-- the map is normally sparse — an unnamed cluster keeps rendering as
-- "Speaker 2". Values come from the same post-meeting extraction pass that
-- produces entities; there is no voiceprint and nothing is matched across
-- meetings, so this is not biometric data.
alter table public.meetings
  add column if not exists speaker_names jsonb;

comment on column public.meetings.speaker_names is
  'Cluster number → person name for this meeting''s diarized speakers. Sparse; unnamed clusters stay "Speaker N". Derived from transcript content, not from voiceprints.';
