-- Per-user profile — the always-on personal context injected into every
-- recap, title, and chat prompt so the model knows who it's assisting from
-- the very first session, before any history exists.
--
-- One row per user (user_id is the PK), RLS-scoped to the owner. All fields
-- are optional: an empty profile injects nothing. The client keeps this in
-- sync via upsert and shows it back in Settings as "what Nod remembers".

create table public.profiles (
    user_id      uuid        primary key references auth.users(id) on delete cascade,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    display_name text,
    role         text,
    focus        text
);

alter table public.profiles enable row level security;

create policy "users read own profile"
    on public.profiles
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "users insert own profile"
    on public.profiles
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "users update own profile"
    on public.profiles
    for update
    to authenticated
    using (auth.uid() = user_id);
