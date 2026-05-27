-- Per-meeting transcript entries. Reverses the earlier "transcript stays
-- in-memory" stance (see `20260523213049_drop_transcript_from_meetings.sql`)
-- because the detail view now exposes a Transcript tab — users expect the
-- recorded conversation to be reviewable, not discarded after the summary
-- is produced.
--
-- One row per Whisper-finalised chunk so we can preserve speaker (source)
-- and timing without parsing concatenated text on read. `idx` is the
-- monotonically-increasing position within the meeting — Whisper's
-- `ended_at` would also order entries chronologically, but two chunks
-- finalised in the same millisecond would tie; `idx` is the cheap
-- deterministic sort key.
--
-- Cascade-deletes with the parent meeting (hard delete) and is gated by
-- the same `auth.uid() = user_id` RLS as `meetings`.

create table public.meeting_transcripts (
    id          uuid        primary key default gen_random_uuid(),
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    user_id     uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    source      text        not null check (source in ('me', 'them')),
    text        text        not null,
    ts          timestamptz not null,
    idx         integer     not null,
    unique (meeting_id, idx)
);

-- Detail view fetch is "all entries for one meeting, ordered". The
-- composite index serves both the WHERE meeting_id = $1 lookup and the
-- ORDER BY idx without a separate sort step.
create index meeting_transcripts_meeting_idx
    on public.meeting_transcripts (meeting_id, idx);

alter table public.meeting_transcripts enable row level security;

create policy "users read own transcripts"
    on public.meeting_transcripts
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own transcripts"
    on public.meeting_transcripts
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users delete own transcripts"
    on public.meeting_transcripts
    for delete
    to authenticated
    using (auth.uid() = user_id);
