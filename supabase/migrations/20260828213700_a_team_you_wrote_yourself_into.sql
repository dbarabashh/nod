-- A team membership two administrators wrote for each other stops being a read
-- of what the team was given.
--
-- `20260828210218` refused `p_user = auth.uid()` in `add_team_member`, which
-- closes the one-call version and nothing else. Two administrators can still add
-- each other and land in any team; `accept_org_invite` inserts a `team_members`
-- row for an invite that names a team without recording who chose it.
--
-- The rule here is exact rather than broad: an administrator legitimately
-- belongs to teams they work in, and an owner adding an administrator to a team
-- is ordinary. What is not ordinary is a pair who each put the other in — that
-- has the shape of the self-add the previous migration refused, taken one step
-- around. Those rows still scope people and tools; they just do not open the
-- content somebody shared with that team.
--
-- What this does NOT close, stated plainly rather than left to be discovered: an
-- administrator can invite an account they control, as an ordinary member, into
-- a team, and read through it. Nothing distinguishes that from hiring somebody.
-- Closing it needs the share to pin its audience when it is made, or the sharer
-- to be told who is in it — a product decision, not a predicate.

-- The invite path records the person who chose the team, which is the inviter
-- and not the person accepting.
create or replace function public.accept_org_invite(p_token uuid)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_invite public.org_invites%rowtype;
    v_email text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select lower(btrim(email)) into v_email from auth.users where id = auth.uid();

    select * into v_invite from public.org_invites where token = p_token;
    if v_invite.id is null then
        raise exception 'this invite is not valid' using errcode = '42704';
    end if;
    if v_invite.accepted_at is not null or v_invite.revoked_at is not null then
        raise exception 'this invite has already been used' using errcode = '42704';
    end if;
    if v_invite.expires_at <= now() then
        raise exception 'this invite has expired' using errcode = '42704';
    end if;
    if lower(v_invite.email) <> coalesce(v_email, '') then
        raise exception 'this invite was sent to a different address' using errcode = '42501';
    end if;

    -- Rejoining reactivates the original row rather than adding a second one, so
    -- the audit trail of a person's time in an organization stays one story.
    insert into public.org_members (org_id, user_id, role)
    values (v_invite.org_id, auth.uid(), v_invite.role)
    on conflict (org_id, user_id) do update
        set role = excluded.role, status = 'active', joined_at = now();

    if v_invite.team_id is not null then
        insert into public.team_members (team_id, user_id, added_by)
        values (v_invite.team_id, auth.uid(), v_invite.invited_by)
        on conflict (team_id, user_id) do nothing;
    end if;

    update public.org_invites
       set accepted_at = now(), accepted_by = auth.uid()
     where id = v_invite.id;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_invite.org_id, auth.uid(), 'member.joined', 'user', auth.uid());

    return v_invite.org_id;
end;
$$;

-- ── One predicate, three callers ────────────────────────────────────────────

-- Whether a team membership is one the content follows.
--
-- Written once because `can_read_folder`, `can_read_meeting_via_grant` and
-- `_meetings_granted_to_me` each spell the same join, and a rule that lives in
-- three places is a rule that will hold in two of them.
create function public._team_membership_grants_content(p_team uuid, p_user uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
        join public.org_members om
          on om.org_id = t.org_id and om.user_id = tm.user_id and om.status = 'active'
        where tm.team_id = p_team
          and tm.user_id = p_user
          and tm.added_by is distinct from tm.user_id
          and not exists (
              -- The other half of a pair who each wrote the other in.
              select 1
                from public.team_members mutual
               where mutual.team_id = tm.team_id
                 and mutual.user_id = tm.added_by
                 and mutual.added_by = tm.user_id
          )
    );
$$;

revoke all on function public._team_membership_grants_content(uuid, uuid) from public, anon;
grant execute on function public._team_membership_grants_content(uuid, uuid) to authenticated;

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
              (fs.team_id is not null
               and public._team_membership_grants_content(fs.team_id, auth.uid()))
              or
              (fs.org_id is not null and exists (
                  select 1 from public.org_members om
                  where om.org_id = fs.org_id and om.user_id = auth.uid() and om.status = 'active'
              ))
          )
    );
$$;

create or replace function public.can_read_meeting_via_grant(p_meeting uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.meeting_grants ms
        where ms.meeting_id = p_meeting
          and (
              (ms.team_id is not null
               and public._team_membership_grants_content(ms.team_id, auth.uid()))
              or
              (ms.org_id is not null and exists (
                  select 1 from public.org_members om
                  where om.org_id = ms.org_id and om.user_id = auth.uid() and om.status = 'active'
              ))
          )
    );
$$;

create or replace function public._meetings_granted_to_me()
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select ms.meeting_id
      from public.meeting_grants ms
     where (ms.team_id is not null
            and public._team_membership_grants_content(ms.team_id, (select auth.uid())))
        or (ms.org_id is not null and exists (
               select 1 from public.org_members om
                where om.org_id = ms.org_id and om.user_id = (select auth.uid()) and om.status = 'active'
           ));
$$;
