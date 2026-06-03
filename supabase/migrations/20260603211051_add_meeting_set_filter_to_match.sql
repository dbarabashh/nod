-- Label-scoped cross-session chat needs to constrain the vector search to the
-- set of sessions carrying a label. match_session_chunks already supports a
-- single-meeting filter (p_meeting_id); add an optional meeting-set filter
-- (p_meeting_ids) for the label path. Both null = search everything (today's
-- behaviour, unchanged).
--
-- Adding a param changes the signature, so drop the old one first.
drop function if exists public.match_session_chunks(vector(384), int, uuid, uuid);

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
as $$
    select
        e.meeting_id,
        e.content,
        1 - (e.embedding <=> query_embedding) as similarity
    from public.session_embeddings e
    where e.user_id = p_user_id
      and (p_meeting_id  is null or e.meeting_id =     p_meeting_id)
      and (p_meeting_ids is null or e.meeting_id = any(p_meeting_ids))
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid, uuid, uuid[])
    to authenticated, service_role;
