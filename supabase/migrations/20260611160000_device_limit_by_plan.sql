-- Make the single-device lock honour the subscription plan's device limit.
--
-- Before: claim_device read a fixed `profiles.device_limit` (default 1) that
-- nothing kept in sync with the plan — so a Pro user (entitled to 3 devices)
-- and trial users (3) were all capped at 1, contradicting pricing.
--
-- After: the limit is derived from the same source as the resolved entitlement
-- — the plan's `limits.devices` with any per-user `limit_overrides` winning.
-- Signature is unchanged, so the llm-proxy caller needs no change.
-- `profiles.device_limit` is left in place but is no longer read.

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

    -- Device limit follows the plan (Starter 1, Pro/Trial 3), with a per-user
    -- limit_override winning — mirrors resolve_entitlement's limit merge. No
    -- subscription row, or an unset value, falls back to 1.
    select greatest(1, coalesce(
        (s.limit_overrides->>'devices')::int,
        (pl.limits->>'devices')::int,
        1
    ))
    into v_limit
    from public.subscriptions s
    join public.plans pl on pl.plan = s.plan
    where s.user_id = p_user_id;
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

revoke all on function public.claim_device(uuid, text, text, text, integer)
    from public, anon, authenticated;
grant execute on function public.claim_device(uuid, text, text, text, integer)
    to service_role;
