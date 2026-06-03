-- Batch B retrieval upgrades.
--
-- #4 Metadata on embeddings — denormalize the session's start time + kind onto
--    each chunk so search can scope by time/kind later without a join, and so
--    a future two-stage (summary→chunk) retrieval needs no backfill.
-- #6 Per-meeting scoping — let the match RPC narrow to one session, so chatting
--    with a long meeting can retrieve its relevant parts instead of stuffing
--    the whole transcript.
-- #3 Hybrid retrieval — a lookup that returns sessions whose extracted entity
--    (person/project/topic) is named in the query, so the proxy can boost
--    those over pure vector similarity.
--
-- Additive (new columns default null; RPC re-created with a defaulted param).

alter table public.session_embeddings add column if not exists started_at timestamptz;
alter table public.session_embeddings add column if not exists kind        text;

-- match RPC gains an optional meeting filter. Adding a param changes the
-- signature, so drop the old one first.
drop function if exists public.match_session_chunks(vector(384), int, uuid);

create or replace function public.match_session_chunks(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid,
    p_meeting_id uuid default null
)
returns table (meeting_id uuid, content text, similarity float)
language sql
stable
as $$
    select
        e.meeting_id,
        e.content,
        1 - (e.embedding <=> query_embedding) as similarity
    from public.session_embeddings e
    where e.user_id = p_user_id
      and (p_meeting_id is null or e.meeting_id = p_meeting_id)
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid, uuid)
    to authenticated, service_role;

-- Sessions whose entity name appears literally in the query text. Length guard
-- avoids 1-2 char entities matching everything. Used to boost vector results.
create or replace function public.meetings_matching_entities(
    p_user_id uuid,
    p_query text
)
returns table (meeting_id uuid)
language sql
stable
as $$
    select distinct me.meeting_id
    from public.entities e
    join public.meeting_entities me on me.entity_id = e.id
    where e.user_id = p_user_id
      and char_length(e.normalized_name) >= 3
      and p_query ilike '%' || e.normalized_name || '%';
$$;

grant execute on function public.meetings_matching_entities(uuid, text)
    to authenticated, service_role;
