-- Which of my sessions are missing from the search index?
--
-- Indexing a session is ~30 sequential proxy calls (2 chunks each, to stay
-- under the edge worker's CPU budget). A run that dies part-way — a 546, the
-- app quitting right after a meeting — used to abandon the rest of the session
-- silently, and nothing ever went back for it. At the time of writing: 22 of
-- 249 prod sessions have no chunks at all and 16 more hold only their opening
-- minutes, across 12 of 34 users. Single-session chat can fall back to the
-- transcript, but corpus-wide retrieval has nowhere to fall back to — an
-- unindexed session simply does not exist for "Ask Nod".
--
-- `indexed_chunk_total` is how many chunks the session's transcript produced.
-- The proxy already receives it on every index call (it prunes stale rows with
-- it) and threw it away; persisting it turns "is this session fully indexed?"
-- into an exact comparison against a count, with no transcript read at all.
-- That is what keeps the check affordable on a multi-year history: the sweep
-- costs one indexed aggregate over `meetings`, not a walk over millions of
-- transcript rows.
alter table public.meetings
    add column if not exists indexed_chunk_total int;

comment on column public.meetings.indexed_chunk_total is
    'Chunks the transcript produced at index time. Written by llm-proxy; a row with fewer chunks in session_embeddings was indexed incompletely.';

-- Sessions recorded before this column existed have it null, and they are
-- exactly the backlog the sweep has to clear. For those we fall back to chunks
-- per minute: healthy sessions land at 0.7–0.8 (~1200 chars each, with
-- overlap). The fallback is tuned for recall, not precision — measured against
-- real transcript sizes on prod, 0.5 catches every genuinely short session at
-- the cost of flagging some healthy ones, while 0.25 missed 7 of 32. A false
-- positive costs one transcript read and is then rejected client-side before
-- any embedding is billed; a miss is a session that stays invisible forever.
-- Every repaired session gets a real total, so the fallback's caseload only
-- shrinks.
--
-- SECURITY INVOKER + an explicit `auth.uid()` predicate: RLS on `meetings`
-- already scopes the rows, and the predicate keeps that true if a future
-- policy widens.
create or replace function public.under_indexed_sessions(
    p_limit int default 5,
    p_since timestamptz default null,
    p_exclude uuid[] default null
)
returns table (meeting_id uuid, expected_chunks int, chunk_count bigint)
language sql
stable
set search_path = ''
as $$
    select
        m.id,
        m.indexed_chunk_total,
        coalesce(e.chunks, 0)
    from public.meetings m
    left join lateral (
        select count(*) as chunks
        from public.session_embeddings se
        where se.meeting_id = m.id
    ) e on true
    where m.user_id = (select auth.uid())
      and m.deleted_at is null
      and m.ended_at is not null
      and (p_since is null or m.started_at >= p_since)
      -- Sessions a caller already measured and found covered. Without this a
      -- heuristic false positive sits at the head of every shortlist and the
      -- sessions that need work never come up.
      and (p_exclude is null or m.id <> all(p_exclude))
      -- Under two minutes there is nothing worth retrieving and the ratio is
      -- noise: a 40-second voice note legitimately yields one chunk.
      and extract(epoch from (m.ended_at - m.started_at)) >= 120
      and case
              when m.indexed_chunk_total is not null
                  then coalesce(e.chunks, 0) < m.indexed_chunk_total
              else coalesce(e.chunks, 0) <
                   0.5 * extract(epoch from (m.ended_at - m.started_at)) / 60.0
          end
    -- Newest first: the sessions a user is most likely to ask about.
    order by m.started_at desc
    limit p_limit;
$$;

grant execute on function public.under_indexed_sessions(int, timestamptz, uuid[])
    to authenticated, service_role;
