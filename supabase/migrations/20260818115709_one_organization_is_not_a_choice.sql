-- `profiles.active_org_id` stops meaning two things at once.
--
-- The column answers "which organization is this person working in", and every
-- server-side reader depends on it: `org_directory` and `org_people` return
-- nothing without it, and `_stamp_org_id_from_context` files a recording by it.
-- Null meant both "has not chosen yet" and "chose to work personally", which are
-- opposite intentions written identically — so no rule of the form "if it is
-- empty, fill it in" could avoid overwriting a deliberate emptiness.
--
-- The macOS client carried that rule in Swift, which is the wrong place twice
-- over: it ran inside a load path, so a launch silently rewrote the profile, and
-- every other client either had to repeat it or disagree with it. Every other
-- transition of this column already lives here — `leave_organization`,
-- `remove_org_member` and `delete_organization` all clear it server-side. Only
-- the setting of it was missing.
--
-- After this, null means exactly one thing: working personally, on purpose.

-- Fires wherever a membership becomes active, so the two RPCs that create one
-- today (`create_organization`, `accept_org_invite`) and any that arrive later
-- are covered without restating the rule in each.
--
-- Never overrides a context already set: `active_org_id is null` is the whole
-- guard. Leaving and removal keep their documented behaviour of returning the
-- person to personal — they set the column to null *after* the membership row
-- changes, so this has already run and found nothing to do.
create function public._adopt_sole_org_as_context()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user  uuid := coalesce(new.user_id, old.user_id);
    v_count integer;
    v_only  uuid;
begin
    select count(*) into v_count
      from public.org_members
     where user_id = v_user and status = 'active';

    if v_count <> 1 then
        return null;
    end if;

    select org_id into v_only
      from public.org_members
     where user_id = v_user and status = 'active';

    update public.profiles
       set active_org_id = v_only
     where user_id = v_user and active_org_id is null;

    return null;
end;
$$;

revoke all on function public._adopt_sole_org_as_context() from public, anon, authenticated;

create trigger adopt_sole_org_as_context
    after insert or update of status on public.org_members
    for each row execute function public._adopt_sole_org_as_context();

-- The one-time correction, and the last moment it can be made safely: no client
-- shipped so far can write a deliberate null — nothing calls the personal branch
-- of the context switch — so every null in this table today means "never chose",
-- and none of them mean "chose personal". Run after that stops being true and it
-- would trample real choices.
update public.profiles p
   set active_org_id = m.org_id
  from public.org_members m
 where p.active_org_id is null
   and m.user_id = p.user_id
   and m.status = 'active'
   and (
       select count(*) from public.org_members x
        where x.user_id = p.user_id and x.status = 'active'
   ) = 1;
