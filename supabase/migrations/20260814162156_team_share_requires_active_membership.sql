-- A team share must also require standing in the organization.
--
-- `can_read_folder` asked only whether a `team_members` row exists. Every path
-- that ends a membership deletes those rows today — `remove_org_member`,
-- `leave_organization`, `delete_organization` — so the two questions currently
-- give the same answer. But they are different questions, and the one being
-- asked is the weaker of them: a team row that outlived its organization
-- membership, through any future path that forgets the cleanup, would keep
-- handing shared folders to somebody who has left the company.
--
-- Making the strong condition the one actually checked means no future code has
-- to remember. Cleanup becomes tidiness rather than the thing access rests on.

create or replace function public.can_read_folder(p_label uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.folder_shares fs
        where fs.label_id = p_label
          and (
              (fs.team_id is not null and exists (
                  select 1
                  from public.team_members tm
                  join public.teams t on t.id = tm.team_id and t.deleted_at is null
                  join public.org_members om
                    on om.org_id = t.org_id and om.user_id = tm.user_id and om.status = 'active'
                  where tm.team_id = fs.team_id and tm.user_id = auth.uid()
              ))
              or
              (fs.org_id is not null and exists (
                  select 1 from public.org_members om
                  where om.org_id = fs.org_id and om.user_id = auth.uid() and om.status = 'active'
              ))
          )
    );
$$;
