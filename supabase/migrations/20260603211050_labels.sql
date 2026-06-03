-- User-defined labels and their session links. A label groups sessions
-- thematically ("Pricing", "1:1s") so the user can browse the library by label
-- and scope a cross-session question to one label's sessions.
--
-- Additive: two standalone tables. meetings / transcripts are untouched.

create table public.labels (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    name       text        not null,
    color      text        not null default '#8B5CF6',
    created_at timestamptz not null default now()
);

-- One label per name per user (case-insensitive), so "Pricing" / "pricing"
-- collapse to one label.
create unique index labels_user_name_idx on public.labels (user_id, lower(name));

create table public.meeting_labels (
    meeting_id uuid        not null references public.meetings(id) on delete cascade,
    label_id   uuid        not null references public.labels(id)   on delete cascade,
    user_id    uuid        not null references auth.users(id)      on delete cascade,
    created_at timestamptz not null default now(),
    primary key (meeting_id, label_id)
);

create index meeting_labels_label_idx   on public.meeting_labels (label_id);
create index meeting_labels_meeting_idx on public.meeting_labels (meeting_id);

alter table public.labels         enable row level security;
alter table public.meeting_labels enable row level security;

create policy "users read own labels"
    on public.labels for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own labels"
    on public.labels for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users update own labels"
    on public.labels for update to authenticated
    using (auth.uid() = user_id);
create policy "users delete own labels"
    on public.labels for delete to authenticated
    using (auth.uid() = user_id);

create policy "users read own meeting_labels"
    on public.meeting_labels for select to authenticated
    using (auth.uid() = user_id);
-- Insert requires owning both the label and the meeting being linked, so a
-- compromised JWT can't attach labels to another user's session.
create policy "users insert own meeting_labels"
    on public.meeting_labels for insert to authenticated
    with check (
        auth.uid() = user_id
        and exists (select 1 from public.meetings m where m.id = meeting_id and m.user_id = auth.uid())
        and exists (select 1 from public.labels  l where l.id = label_id   and l.user_id = auth.uid())
    );
create policy "users delete own meeting_labels"
    on public.meeting_labels for delete to authenticated
    using (auth.uid() = user_id);
