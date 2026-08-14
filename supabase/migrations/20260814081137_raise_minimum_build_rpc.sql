-- Lets the release pipeline raise the update floor once a build is provably
-- live (`scripts/release.sh --min-build`, called only after the appcast and DMG
-- both answer 200).
--
-- `greatest` rather than a plain assignment: lowering the floor would silently
-- un-gate clients an earlier release deliberately blocked, and a mistyped
-- argument on the command line is exactly how that would happen. The function
-- can only ever move the gate in the direction that is safe to get wrong.
--
-- SECURITY INVOKER (the default) on purpose — the grant below is the whole
-- authorization story, so there is no definer privilege to escape from.
create or replace function public.raise_minimum_build(
    p_platform text,
    p_build integer
)
returns integer
language plpgsql
as $$
declare
    v_minimum_build integer;
begin
    update public.app_config
    set minimum_build = greatest(minimum_build, p_build),
        updated_at    = now()
    where platform = p_platform
    returning minimum_build into v_minimum_build;

    if v_minimum_build is null then
        raise exception 'no app_config row for platform %', p_platform;
    end if;

    return v_minimum_build;
end;
$$;

revoke all on function public.raise_minimum_build(text, integer) from public;
grant execute on function public.raise_minimum_build(text, integer) to service_role;
