-- Retrieval must not read sessions the user deleted.
--
-- `session_embeddings` cascades on hard delete only, and trashing a meeting is
-- a soft delete (`deleted_at`), so a trashed session's chunks stayed in the
-- index and kept grounding answers. The client can't even name them — its
-- meetings list is `deleted_at is null` — so they surfaced as "A past session"
-- source chips that open nothing. At the time of writing: 5 trashed meetings,
-- 16 live chunks in prod.
--
-- Filtered at query time rather than deleted on trash: restoring from trash has
-- to bring the session back whole, and re-embedding a restored transcript would
-- cost a full pass over it.
--
-- The join sits inside the shortlist subquery, before `limit` — filtering after
-- it would quietly return fewer rows than `match_count`.
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
        join public.meetings m on m.id = e.meeting_id
        where e.user_id = p_user_id
          and m.deleted_at is null
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

-- The same hole, one function over. Today it only re-ranks rows
-- `match_session_chunks` already returned, so a trashed meeting can't enter
-- through it — but that is a property of one caller, not of the function, and
-- the next caller that uses it to *select* would reopen the bug.
create or replace function public.meetings_matching_entities(
    p_user_id uuid,
    p_query text
)
returns table (meeting_id uuid)
language sql
stable
set search_path = ''
as $$
    select distinct me.meeting_id
    from public.entities e
    join public.meeting_entities me on me.entity_id = e.id
    join public.meetings m on m.id = me.meeting_id
    where e.user_id = p_user_id
      and m.deleted_at is null
      and char_length(e.normalized_name) >= 3
      and position(e.normalized_name in lower(p_query)) > 0;
$$;

grant execute on function public.meetings_matching_entities(uuid, text)
    to authenticated, service_role;
