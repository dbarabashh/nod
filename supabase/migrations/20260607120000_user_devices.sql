-- Single-device lock — one account may be active on one device at a time.
--
-- Shaped so a future "N devices" tier is a column bump, not a redesign:
-- `user_devices` holds one row per (user, device); `profiles.device_limit`
-- (default 1) is the per-user cap. The lock is enforced server-side in the
-- `llm-proxy` Edge Function — every authenticated call runs `claim_device`,
-- and a device that exceeds the cap is refused (403) so the client signs out.
-- A device that hasn't called in within the TTL frees its slot, so quitting
-- (or just leaving) one machine lets another in without manual cleanup.

create table public.user_devices (
    user_id      uuid        not null references auth.users(id) on delete cascade,
    device_id    text        not null,
    device_name  text,
    platform     text        not null default 'macos',
    bound_at     timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    primary key (user_id, device_id)
);

create index user_devices_user_last_seen
    on public.user_devices (user_id, last_seen_at desc);

alter table public.user_devices enable row level security;

-- Read-only to the owner (for a future "your devices" settings screen).
-- Binding/eviction happens server-side with the service role in llm-proxy, so
-- there are deliberately no client insert/update/delete policies.
create policy "users read own devices"
    on public.user_devices
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Per-user device cap. 1 = hard single-device lock (today's policy). Raising
-- this for a user (or changing the default) is how a multi-device tier ships.
-- `>= 1` guards against a 0/negative cap that would lock the user out entirely.
alter table public.profiles
    add column device_limit integer not null default 1
    check (device_limit >= 1);

-- Atomic claim: returns true if this device may use the account, false if the
-- cap is already taken by other (recently-active) devices.
--
-- The per-user advisory lock serializes concurrent claims so two new devices
-- can't both pass the capacity check and over-fill the cap. Stale rows (not
-- seen within p_ttl_seconds) are pruned first so an abandoned device frees its
-- slot. `security definer` + the revoke below keep this callable only by the
-- service role from the Edge Function — never directly by a client JWT.
create or replace function public.claim_device(
    p_user_id uuid,
    p_device_id text,
    p_device_name text,
    p_platform text,
    p_ttl_seconds integer
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_limit  integer;
    v_active integer;
    v_exists boolean;
begin
    perform pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

    delete from public.user_devices
    where user_id = p_user_id
      and device_id <> p_device_id
      and last_seen_at < now() - pg_catalog.make_interval(secs => p_ttl_seconds);

    select coalesce(device_limit, 1) into v_limit
    from public.profiles
    where user_id = p_user_id;
    if v_limit is null then
        v_limit := 1;
    end if;

    select exists(
        select 1 from public.user_devices
        where user_id = p_user_id and device_id = p_device_id
    ) into v_exists;

    if v_exists then
        update public.user_devices
        set last_seen_at = now(),
            device_name  = coalesce(p_device_name, device_name)
        where user_id = p_user_id and device_id = p_device_id;
        return true;
    end if;

    select count(*) into v_active
    from public.user_devices
    where user_id = p_user_id;

    if v_active >= v_limit then
        return false;
    end if;

    insert into public.user_devices (user_id, device_id, device_name, platform)
    values (p_user_id, p_device_id, p_device_name, coalesce(p_platform, 'macos'));
    return true;
end;
$$;

-- Revoke from everyone, then grant only to service_role: the function is
-- security definer (bypasses RLS) and trusts p_user_id, so a direct
-- authenticated caller could bind/evict another user's devices. Only the
-- llm-proxy (service role, after verifying the JWT) may call it. The explicit
-- service_role grant is required because the revoke above drops the default
-- PUBLIC grant — without it every claim_device call would error and the lock
-- would silently fail open.
revoke all on function public.claim_device(uuid, text, text, text, integer)
    from public, anon, authenticated;
grant execute on function public.claim_device(uuid, text, text, text, integer)
    to service_role;
