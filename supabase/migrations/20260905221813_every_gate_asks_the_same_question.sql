-- Two gates were still asking `subscriptions` instead of the resolver.
--
-- `20260905205944` claimed that teaching `resolve_entitlement` about
-- organizations was the whole of the enforcement work, because every gate read
-- it. Two did not, and a review of the tier edge cases found them:
--
--   * `has_feature`, which the `screen_observations` policies call to gate
--     Ambient Context, joined `subscriptions` to `plans` itself. A member the
--     workspace covers but who holds no personal subscription — the ordinary
--     Teams employee — got no Ambient Context at all, and one on personal
--     Starter got Starter's answer while resolving to Teams everywhere else.
--   * `claim_device` did the same for the device limit, so the same employee was
--     held to one Mac when the workspace plan grants three.
--
-- Both now read the resolver. `has_feature` becomes SECURITY DEFINER to do so —
-- the resolver is service-role only, deliberately — and stays pinned to
-- `auth.uid()`, so it can still only ever answer about the caller. The policies
-- keep it in a scalar subquery, which is what makes it an InitPlan evaluated
-- once per statement rather than once per row on the schema's busiest table.
--
-- The third fix is smaller: `20260905205717` gave the Teams plan a literal
-- `limits` and left out `ios_companions`, which `claim_device` reads. Copied
-- from Pro now, like its features were.

create or replace function public.has_feature(p_feature text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (public.resolve_entitlement((select auth.uid()))->'features') ? p_feature,
    false
  );
$$;

revoke all on function public.has_feature(text) from public, anon;
grant execute on function public.has_feature(text) to authenticated;

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
    v_platform text;
    v_limits   jsonb;
    v_limit    integer;
    v_active   integer;
    v_exists   boolean;
begin
    v_platform := case when p_platform = 'ios' then 'ios' else 'macos' end;
    perform pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

    delete from public.user_devices
    where user_id = p_user_id
      and device_id <> p_device_id
      and last_seen_at < now() - pg_catalog.make_interval(secs => p_ttl_seconds);

    -- The resolver's merged limits: the plan somebody actually resolves to —
    -- their workspace's, or their own — with any override already applied.
    v_limits := public.resolve_entitlement(p_user_id)->'limits';
    v_limit := greatest(1, coalesce(
        case
            when v_platform = 'ios' then (v_limits->>'ios_companions')::int
            else (v_limits->>'devices')::int
        end,
        1
    ));

    select exists(
        select 1 from public.user_devices
        where user_id = p_user_id and device_id = p_device_id
    ) into v_exists;

    if v_exists then
        update public.user_devices
        set last_seen_at = now(),
            device_name = coalesce(p_device_name, device_name),
            platform = v_platform
        where user_id = p_user_id and device_id = p_device_id;
        return true;
    end if;

    select count(*) into v_active
    from public.user_devices
    where user_id = p_user_id and platform = v_platform;

    if v_active >= v_limit then
        return false;
    end if;

    insert into public.user_devices (user_id, device_id, device_name, platform)
    values (p_user_id, p_device_id, p_device_name, v_platform);
    return true;
end;
$$;

revoke all on function public.claim_device(uuid, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.claim_device(uuid, text, text, text, integer) to service_role;

update public.plans as t
   set limits = t.limits || jsonb_build_object('ios_companions', p.limits->'ios_companions')
  from public.plans as p
 where t.plan = 'teams'
   and p.plan = 'pro'
   and p.limits ? 'ios_companions'
   and not (t.limits ? 'ios_companions');
