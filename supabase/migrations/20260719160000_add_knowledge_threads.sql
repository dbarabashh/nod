-- Cross-session ("Ask Nod") conversations, as resumable threads.
--
-- `chat_messages` can't hold these: its `meeting_id` is NOT NULL, because a
-- per-meeting chat is scoped to exactly one session. A cross-session thread is
-- scoped to none of them, so it gets its own pair of tables rather than a
-- nullable column that would make every existing query ambiguous.

create table public.knowledge_threads (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    -- The first question asked in the thread, trimmed. Renameable later.
    title      text        not null default '',
    created_at timestamptz not null default now(),
    -- Bumped on every turn so the list orders by "last used", not "created".
    updated_at timestamptz not null default now()
);

create index knowledge_threads_user_idx
    on public.knowledge_threads (user_id, updated_at desc);

create table public.knowledge_messages (
    id         uuid        primary key default gen_random_uuid(),
    thread_id  uuid        not null references public.knowledge_threads(id) on delete cascade,
    user_id    uuid        not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    role       text        not null check (role in ('user', 'assistant')),
    content    text        not null,
    -- The sessions the answer drew on, and the passages it stood on, so a
    -- reopened thread still shows its evidence instead of a bare answer.
    sources    jsonb       not null default '[]'::jsonb,
    evidence   jsonb       not null default '[]'::jsonb
);

create index knowledge_messages_thread_idx
    on public.knowledge_messages (thread_id, created_at);

alter table public.knowledge_threads enable row level security;
alter table public.knowledge_messages enable row level security;

create policy "users read own knowledge threads"
    on public.knowledge_threads
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own knowledge threads"
    on public.knowledge_threads
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users update own knowledge threads"
    on public.knowledge_threads
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Hard delete, not a soft one: the UI offers "delete", there is no trash to
-- restore a thread from, and a row that outlives the word would contradict it.
-- Messages cascade.
create policy "users delete own knowledge threads"
    on public.knowledge_threads
    for delete
    to authenticated
    using (auth.uid() = user_id);

create policy "users read own knowledge messages"
    on public.knowledge_messages
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own knowledge messages"
    on public.knowledge_messages
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users delete own knowledge messages"
    on public.knowledge_messages
    for delete
    to authenticated
    using (auth.uid() = user_id);
