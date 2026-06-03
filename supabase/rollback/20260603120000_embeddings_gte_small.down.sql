-- Rollback for 20260603120000_embeddings_gte_small.sql
-- Restores the 1536-dim column + the auth.uid()-scoped RPC signature.
-- Safe only while session_embeddings holds no 384-dim rows (truncate first
-- if it does — they can't be cast up to 1536).

truncate table public.session_embeddings;

drop index if exists public.session_embeddings_vec_idx;
drop function if exists public.match_session_chunks(vector(384), int, uuid);

alter table public.session_embeddings
    alter column embedding type vector(1536);

create index session_embeddings_vec_idx
    on public.session_embeddings
    using hnsw (embedding vector_cosine_ops);

create or replace function public.match_session_chunks(
    query_embedding vector(1536),
    match_count int
)
returns table (meeting_id uuid, content text, similarity float)
language sql
stable
as $$
    select e.meeting_id, e.content, 1 - (e.embedding <=> query_embedding) as similarity
    from public.session_embeddings e
    where e.user_id = auth.uid()
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(1536), int) to authenticated;
