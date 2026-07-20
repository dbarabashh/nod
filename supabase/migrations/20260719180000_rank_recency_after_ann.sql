-- Fixes how the recency prior added in 20260719170000 interacts with the index.
--
-- That version ordered by `similarity + decay` directly, which is an arbitrary
-- expression — pgvector's HNSW index can only serve `ORDER BY embedding <=> q`,
-- so the planner had no way to use `session_embeddings_vec_idx` and fell back
-- to scanning every one of the user's chunks. Verified on the sandbox: with
-- seq scans penalised, the pure-distance form plans as
-- "Index Scan using session_embeddings_vec_idx", the expression form as
-- "Seq Scan + Sort". Invisible at a few hundred chunks, linear in the corpus
-- after that.
--
-- Two stages instead: the inner query takes the nearest neighbours through the
-- index, the outer one re-ranks that shortlist by recency. Same intent, same
-- weight, and the index does the work it exists for.
create or replace function public.match_session_chunks(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid,
    p_meeting_id uuid default null,
    p_meeting_ids uuid[] default null
)
returns table (meeting_id uuid, content text, similarity float)
language sql
stable
set search_path = ''
as $$
    select c.meeting_id, c.content, c.similarity
    from (
        select
            e.meeting_id,
            e.content,
            1 - (e.embedding OPERATOR(public.<=>) query_embedding) as similarity,
            coalesce(e.started_at, e.created_at) as occurred_at
        from public.session_embeddings e
        where e.user_id = p_user_id
          and (p_meeting_id  is null or e.meeting_id =     p_meeting_id)
          and (p_meeting_ids is null or e.meeting_id = any(p_meeting_ids))
        -- Index-served. Over-fetched so recency has a shortlist worth
        -- reordering; too tight a shortlist and the prior can't do anything.
        order by e.embedding OPERATOR(public.<=>) query_embedding
        limit greatest(match_count * 4, 40)
    ) c
    order by c.similarity
        + 0.06 * exp(-extract(epoch from (now() - c.occurred_at)) / 2592000.0) desc
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid, uuid, uuid[])
    to authenticated, service_role;
