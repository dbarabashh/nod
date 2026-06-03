-- Entities + session links — the invisible graph (step 4). Each session is
-- linked to the people, projects, and topics it mentions, extracted by the
-- LLM at finalize time. This powers "Related sessions" and entity-scoped
-- views WITHOUT ever showing the user a node-and-edges diagram.
--
-- Additive: two standalone tables. meetings / transcripts are untouched.

create table public.entities (
    id              uuid        primary key default gen_random_uuid(),
    user_id         uuid        not null references auth.users(id) on delete cascade,
    kind            text        not null check (kind in ('person', 'project', 'topic')),
    name            text        not null,
    -- Lowercased/trimmed form used for de-duplication so "Project Atlas" and
    -- "project atlas" collapse to one node per user.
    normalized_name text        not null,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    unique (user_id, kind, normalized_name)
);

create index entities_user_kind_idx on public.entities (user_id, kind);

create table public.meeting_entities (
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    entity_id   uuid        not null references public.entities(id) on delete cascade,
    user_id     uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (meeting_id, entity_id)
);

create index meeting_entities_entity_idx  on public.meeting_entities (entity_id);
create index meeting_entities_meeting_idx on public.meeting_entities (meeting_id);

alter table public.entities         enable row level security;
alter table public.meeting_entities enable row level security;

create policy "users read own entities"
    on public.entities for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own entities"
    on public.entities for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users update own entities"
    on public.entities for update to authenticated
    using (auth.uid() = user_id);

create policy "users read own meeting_entities"
    on public.meeting_entities for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own meeting_entities"
    on public.meeting_entities for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users delete own meeting_entities"
    on public.meeting_entities for delete to authenticated
    using (auth.uid() = user_id);
