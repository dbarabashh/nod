-- External agent connections — personal access tokens that let a user's OWN AI
-- client (Claude, ChatGPT, Gemini, …) pull their meetings through the `connect`
-- edge function. Provider-agnostic by design: the token and the data API are
-- identical for every client; only the local setup differs per provider.
--
-- Security contract:
--   - The raw token is generated AND sha256-hashed ON-DEVICE (CryptoKit). The
--     server only ever stores/sees the hex hash — never the raw secret. There is
--     no way to recover a token from this table; a lost token is revoked + reissued.
--   - Read-only, per-user, revocable. `connect` resolves a request to a user_id
--     by hashing the bearer token and matching `token_hash` (service role, since
--     the token is not a Supabase JWT and cannot drive RLS directly).
--   - `client` and `scopes` are forward-looking: `client` labels which app the
--     connection is for (informational); `scopes` lets us widen beyond
--     read-only later without a schema change.

create table public.connections (
    id           uuid        primary key default gen_random_uuid(),
    user_id      uuid        not null references auth.users(id) on delete cascade,
    token_hash   text        not null unique,
    name         text        not null,
    client       text        not null default 'other',
    scopes       text[]      not null default array['meetings:read'],
    created_at   timestamptz not null default now(),
    last_used_at timestamptz,
    revoked_at   timestamptz
);

create index connections_user_idx
    on public.connections (user_id)
    where revoked_at is null;

alter table public.connections enable row level security;

-- Owners fully manage their own connections. The `connect` edge function reads
-- with the service role (the token is not a JWT), so there is NO anon/public
-- policy here — nothing reaches `connections` without either the owner's JWT or
-- the service role behind the token gate.
create policy "owners read own connections"
    on public.connections
    for select
    to authenticated
    using (auth.uid() = user_id);

create policy "owners insert own connections"
    on public.connections
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "owners update own connections"
    on public.connections
    for update
    to authenticated
    using (auth.uid() = user_id);

-- Mint a connection for the caller. The raw token NEVER reaches the server — the
-- client generates it and hashes it on-device, passing only the hex sha256 here.
-- SECURITY DEFINER so the insert is atomic and `user_id` is pinned to the caller
-- regardless of the supplied payload.
create or replace function public.create_connection(
    p_name       text,
    p_client     text,
    p_token_hash text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'invalid token hash';
    end if;

    insert into public.connections (user_id, token_hash, name, client)
    values (
        auth.uid(),
        p_token_hash,
        coalesce(nullif(btrim(p_name), ''), 'Connection'),
        coalesce(nullif(btrim(p_client), ''), 'other')
    )
    returning id into v_id;

    return v_id;
end;
$$;

-- Revoke a connection (soft — keeps the row so `last_used_at` history survives).
-- Owner only; a revoked connection's token is dead on the next `connect` request.
create or replace function public.revoke_connection(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.connections
    set revoked_at = now()
    where id = p_id
      and user_id = auth.uid()
      and revoked_at is null;
end;
$$;

revoke all on function public.create_connection(text, text, text) from public;
revoke all on function public.revoke_connection(uuid)             from public;

grant execute on function public.create_connection(text, text, text) to authenticated;
grant execute on function public.revoke_connection(uuid)             to authenticated;
