-- Who is in my organization, for a member rather than an administrator.
--
-- `list_org_members` and `list_team_members` both stop at `_assert_org_admin`,
-- deliberately: the roster is readable org-wide through RLS, but a list of
-- everyone's address is a different thing to hand out. That boundary made the
-- assistant useless for the sentence people actually say — "book a meeting with
-- Dima" — because inviting somebody needs their address and only admins could
-- see one. A person had to read the address off another screen and type it in,
-- which does not scale past a team you know by heart.
--
-- So: any active member may look up their own colleagues, and gets exactly the
-- two fields an invitation needs. Not a general directory dump — the caller's
-- own organization only, active members only, no roles, no join dates, no
-- invite tokens, and nothing at all when the caller belongs to no organization.
-- An invitation reveals the address to the guest in any case, so this widens who
-- can send one rather than what anybody can learn.

create or replace function public.org_directory()
    returns table (user_id uuid, display_name text, email text)
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
declare
    v_caller uuid := auth.uid();
    v_org uuid;
begin
    if v_caller is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    -- The caller's own membership is the authorization: no active membership in
    -- the organization they are scoped to, no directory.
    select p.active_org_id into v_org
      from public.profiles p
     where p.user_id = v_caller;
    if v_org is null then
        return;
    end if;
    if not exists (
        select 1 from public.org_members m
         where m.org_id = v_org and m.user_id = v_caller and m.status = 'active'
    ) then
        return;
    end if;

    return query
        select m.user_id,
               nullif(btrim(pr.display_name), ''),
               lower(u.email)
          from public.org_members m
          join auth.users u on u.id = m.user_id
          left join public.profiles pr on pr.user_id = m.user_id
         where m.org_id = v_org
           and m.status = 'active'
         order by nullif(btrim(pr.display_name), ''), lower(u.email);
end;
$$;

revoke all on function public.org_directory() from public, anon;
grant execute on function public.org_directory() to authenticated;
