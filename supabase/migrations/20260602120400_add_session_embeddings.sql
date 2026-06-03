-- Cross-session semantic memory (step 5). Each session's transcript is split
-- into chunks, embedded at finalize time, and stored here so the user can ask
-- questions across everything they've ever recorded. A cosine-similarity RPC
-- (RLS-scoped to the owner) does the retrieval.
--
-- Adds an embeddings provider to the stack — see docs/policies updates.
-- Additive: standalone table + extension + one RPC + a widened usage check.

create extension if not exists vector;

create table public.session_embeddings (
    id          uuid          primary key default gen_random_uuid(),
    meeting_id  uuid          not null references public.meetings(id) on delete cascade,
    user_id     uuid          not null references auth.users(id) on delete cascade,
    chunk_idx   int           not null,
    content     text          not null,
    embedding   vector(1536)  not null,
    created_at  timestamptz   not null default now(),
    unique (meeting_id, chunk_idx)
);

create index session_embeddings_meeting_idx
    on public.session_embeddings (meeting_id);

-- HNSW cosine index for fast approximate nearest-neighbour search.
create index session_embeddings_vec_idx
    on public.session_embeddings
    using hnsw (embedding vector_cosine_ops);

alter table public.session_embeddings enable row level security;

create policy "users read own embeddings"
    on public.session_embeddings for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own embeddings"
    on public.session_embeddings for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users delete own embeddings"
    on public.session_embeddings for delete to authenticated
    using (auth.uid() = user_id);

-- Retrieval RPC. SECURITY INVOKER (the default) so the caller's RLS applies;
-- the explicit `user_id = auth.uid()` keeps the planner from scanning other
-- users' rows. Returns the closest chunks across ALL the caller's sessions.
create or replace function public.match_session_chunks(
    query_embedding vector(1536),
    match_count int
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
    where e.user_id = auth.uid()
    order by e.embedding <=> query_embedding
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(1536), int) to authenticated;

-- Let the llm-proxy record embedding calls for cost accounting.
alter table public.usage_events drop constraint usage_events_kind_check;
alter table public.usage_events add constraint usage_events_kind_check
    check (kind in ('chat', 'transcribe', 'embed'));
