-- Switch cross-session embeddings to Supabase's built-in `gte-small` model
-- (384-dim), generated inside the Edge Function — no external embeddings
-- provider, no client-side vector formatting. The whole index/search path
-- now runs server-side, so this also removes the text→vector cast ambiguity
-- that could silently drop inserts.
--
-- Safe: `session_embeddings` is empty (the OpenRouter embed path never
-- successfully wrote a row), so re-dimensioning the column is a no-op on data.

drop index if exists public.session_embeddings_vec_idx;
drop function if exists public.match_session_chunks(vector(1536), int);

alter table public.session_embeddings
    alter column embedding type vector(384);

create index session_embeddings_vec_idx
    on public.session_embeddings
    using hnsw (embedding vector_cosine_ops);

-- Search RPC now takes an explicit user id: the Edge Function calls it with
-- the service role after verifying the JWT, so it can't rely on auth.uid().
-- RLS on the table still independently scopes rows to the owner.
create or replace function public.match_session_chunks(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid
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
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid)
    to authenticated, service_role;
