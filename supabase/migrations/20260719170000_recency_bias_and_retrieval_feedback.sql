-- Two changes that make retrieval personal rather than generic.
--
-- 1. A recency prior in the ranking. Cosine similarity alone has no idea that
--    "the pricing decision" almost always means the LATEST one — it happily
--    returns a better-worded discussion from six months ago. `started_at` is
--    already denormalised onto every chunk, so the fix costs nothing per query.
--
--    The bonus is small on purpose (0.06 against a similarity range of roughly
--    0.3–0.8) and decays with a ~30-day constant: it breaks ties between
--    comparable passages and nudges a near-tie, but never drags an unrelated
--    recent chunk over a strong older match.
--
--    `similarity` keeps returning the raw cosine — the client's 0.3 floor and
--    the edge function's entity boost both reason about it, and quietly
--    returning a blended score there would move that floor's meaning.
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
    order by
        (1 - (e.embedding OPERATOR(public.<=>) query_embedding))
        + 0.06 * exp(
            -extract(epoch from (now() - coalesce(e.started_at, e.created_at))) / 2592000.0
        ) desc
    limit match_count;
$$;

grant execute on function public.match_session_chunks(vector(384), int, uuid, uuid, uuid[])
    to authenticated, service_role;

-- 2. Which retrieved session the user actually opened.
--
--    Clicking a source is the strongest relevance signal the product will ever
--    get, and it was being thrown away. Recording it is what makes reranking
--    possible later; without it the system can only ever fail silently.
create table public.retrieval_feedback (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    -- The question as asked, so a future reranker can learn per-query-type.
    question   text        not null,
    meeting_id uuid        not null references public.meetings(id) on delete cascade,
    -- Where the opened session sat in the list. Position 0 being clicked says
    -- something very different from position 5.
    rank       int         not null
);

create index retrieval_feedback_user_idx
    on public.retrieval_feedback (user_id, created_at desc);

alter table public.retrieval_feedback enable row level security;

create policy "users read own retrieval feedback"
    on public.retrieval_feedback
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own retrieval feedback"
    on public.retrieval_feedback
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users delete own retrieval feedback"
    on public.retrieval_feedback
    for delete
    to authenticated
    using (auth.uid() = user_id);
