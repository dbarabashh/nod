-- `profiles.active_org_id` becomes something the server checked.
--
-- The column is load-bearing authorization input: `org_directory`, `org_people`,
-- `same_meeting_in_org`, `_stamp_org_id_from_context`, `_stamp_lease_identity`,
-- `find_live_room` and `join_live_room` all read it to decide which
-- organization's rows the caller may reach. It has never been validated. The
-- only write policy on `profiles` is `using ((select auth.uid()) = user_id)`
-- with no `with check` and no column list, so any signed-in account could PATCH
-- it to any organization id and be answered as though it belonged there.
--
-- The readers that noticed added their own membership check afterwards; the two
-- live-room functions did not, which is the bug this closes at its source rather
-- than in each caller. A guard here also covers every reader written later,
-- which is the property that was actually missing.
--
-- Membership, not existence: an organization id you once belonged to stays valid
-- forever otherwise, so a deprovisioned account keeps the one value that would
-- let it back in.

create function public._assert_context_is_yours()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if new.active_org_id is not null
       and new.active_org_id is distinct from old.active_org_id
       and not public._is_org_member_of(new.active_org_id, new.user_id) then
        raise exception 'you are not a member of that organization'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

revoke all on function public._assert_context_is_yours() from public, anon, authenticated;

-- `of active_org_id` so an ordinary display-name write pays nothing, and
-- `before` so the row never lands. Insert is covered separately below: `old` is
-- null there, and a profile is created before any membership exists.
create trigger assert_context_is_yours
    before update of active_org_id on public.profiles
    for each row execute function public._assert_context_is_yours();

create function public._assert_new_context_is_yours()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if new.active_org_id is not null
       and not public._is_org_member_of(new.active_org_id, new.user_id) then
        raise exception 'you are not a member of that organization'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

revoke all on function public._assert_new_context_is_yours() from public, anon, authenticated;

create trigger assert_new_context_is_yours
    before insert on public.profiles
    for each row execute function public._assert_new_context_is_yours();

-- Values that were already wrong. The trigger only sees writes, so a profile
-- pointing at an organization the account has since left would keep pointing
-- there until something happened to touch it — which for a deprovisioned
-- account is never.
update public.profiles p
   set active_org_id = null
 where p.active_org_id is not null
   and not exists (
       select 1 from public.org_members m
        where m.org_id = p.active_org_id
          and m.user_id = p.user_id
          and m.status = 'active'
   );
