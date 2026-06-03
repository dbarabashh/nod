-- Per-session chat — the running conversation the user has with one recorded
-- session (step 3). Each row is one turn; cascade-deletes with its parent
-- meeting so a deleted session never leaves orphaned chat behind.
--
-- Additive: standalone table, no change to meetings / meeting_transcripts.

create table public.chat_messages (
    id          uuid        primary key default gen_random_uuid(),
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    user_id     uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    role        text        not null check (role in ('user', 'assistant')),
    content     text        not null
);

create index chat_messages_meeting_idx
    on public.chat_messages (meeting_id, created_at);

alter table public.chat_messages enable row level security;

create policy "users read own chat"
    on public.chat_messages
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own chat"
    on public.chat_messages
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users delete own chat"
    on public.chat_messages
    for delete
    to authenticated
    using (auth.uid() = user_id);
