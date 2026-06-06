-- Pin search_path on our four custom functions (lint 0011,
-- function_search_path_mutable). All are SECURITY INVOKER today so the
-- escalation risk is low, but an unpinned search_path is exploitable the
-- moment any of them switches to SECURITY DEFINER — fix it now while it's
-- cheap.
--
-- Three of them only touch public.* (already schema-qualified) and
-- auth.uid() / pg_catalog builtins, so an empty search_path is safe with no
-- body change — pg_catalog is always implicitly searched.
alter function public.meetings_matching_entities(uuid, text) set search_path = '';
alter function public.soft_delete_meeting(uuid)              set search_path = '';
alter function public.restore_meeting(uuid)                  set search_path = '';

-- match_session_chunks is the exception: the pgvector `<=>` operator lives in
-- the public schema, so under search_path = '' it would no longer resolve.
-- Qualify the operator explicitly (OPERATOR(public.<=>)) — same operator, so
-- the vector index is still used and results are identical — and pin the path.
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
    select
        e.meeting_id,
        e.content,
        1 - (e.embedding OPERATOR(public.<=>) query_embedding) as similarity
    from public.session_embeddings e
    where e.user_id = p_user_id
      and (p_meeting_id  is null or e.meeting_id =     p_meeting_id)
      and (p_meeting_ids is null or e.meeting_id = any(p_meeting_ids))
    order by e.embedding OPERATOR(public.<=>) query_embedding
    limit match_count;
$$;
