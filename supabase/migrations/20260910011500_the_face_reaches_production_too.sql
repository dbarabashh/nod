-- `20260909233328_a_face_that_changes_is_seen` never reached production.
--
-- It was stamped on the sandbox branch at 23:33:28 while production had already
-- applied `20260909235047`, so the git-driven deploy read it as older than the
-- history it had and skipped it. Nothing failed and nothing said so: the branch
-- had the trigger, production did not, and an organization's new logo went on
-- reaching nobody on live.
--
-- Repeated here rather than by renaming the original, because the original is
-- what the sandbox's own history records and editing an applied migration to
-- make history look correct is exactly what `supabase.md` forbids. So this is a
-- forward migration that converges both instances, and it is written to be
-- applied twice without noticing — `drop trigger if exists` ahead of the create,
-- `create or replace` for the function.
--
-- The lesson worth keeping: a migration authored with a timestamp behind the
-- target's last applied version is silently skipped there. Version numbers are
-- not just names.

do $$
begin
    if to_regprocedure('public._notify_access_changed(text)') is null then
        raise exception
            'access broadcasting is not set up on this branch: apply 20260815100636 first';
    end if;
end $$;

create or replace function public._broadcast_org_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    begin
        perform public._notify_access_changed('org:' || new.id::text);
    exception when others then
        -- Loud but not fatal. Renaming an organization must not fail because
        -- the message about it could not be sent, and a silently dead
        -- broadcast is indistinguishable from one nobody needed.
        raise warning 'broadcast_org_change failed: %', sqlerrm;
    end;
    return null;
end;
$$;

revoke all on function public._broadcast_org_change() from public, anon, authenticated, service_role;

drop trigger if exists broadcast_access on public.organizations;

create trigger broadcast_access after update on public.organizations
    for each row
    when (
        old.logo_path is distinct from new.logo_path
        or old.name is distinct from new.name
    )
    execute function public._broadcast_org_change();
