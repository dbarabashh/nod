-- Rollback for 20260603140000_hybrid_retrieval.sql
-- Restores the single-arg-less match RPC (user only), drops the hybrid lookup
-- and the metadata columns. session_embeddings data is otherwise untouched.

drop function if exists public.meetings_matching_entities(uuid, text);
drop function if exists public.match_session_chunks(vector(384), int, uuid, uuid);

create or replace function public.match_session_chunks(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid
)
returns table (meeting_id uuid, content text, similarity float)
language sql
stable
as $$
    select e.meeting_id, e.content, 1 - (e.embedding <=> query_embedding) as similarity
    from public.session_embeddings e
    where e.user_id = p_user_id
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid) to authenticated, service_role;

alter table public.session_embeddings drop column if exists started_at;
alter table public.session_embeddings drop column if exists kind;
