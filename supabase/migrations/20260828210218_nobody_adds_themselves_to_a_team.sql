-- An administrator stops being able to add themselves to a team.
--
-- `20260814112951` made `admin_content_access` a switch of its own and said why:
-- "a security review needs to hear that data can be retrieved on request, and a
-- member needs it not to be true by accident on the day they join". It defaults
-- to off, `can_admin_read_org_content` is the only reader, and — checked against
-- the schema, not the intent — there is no update policy on `org_policies`, no
-- grant beyond `select`, and no RPC anywhere that writes the column. An
-- administrator cannot turn it on.
--
-- They could reach the same content anyway. `20260814152612` and
-- `20260815204500` later made team membership a read grant —
-- `can_read_folder` and `can_read_meeting_via_grant` both answer yes on a
-- `team_members` row — and `add_team_member` never checked that the person being
-- added was somebody other than the person asking. So one call put an
-- administrator inside a team and handed them the meetings, transcripts, action
-- items and embeddings a member had shared with that team and with nobody else.
--
-- `team_rpcs.sql` opens by calling a team "the boundary of people and tools, not
-- of content", which was true when it was written and stopped being true two
-- migrations later. This restores the part of it that can be restored here.

-- Who put somebody in a team, on the row rather than only in `audit_log`. The
-- log answers "what happened"; a grant that depends on this membership needs to
-- be able to ask "and who decided that" without a join to a table only
-- administrators can read. Null means the person arrived with an invitation that
-- already named the team, which is the inviter's choice and not a later one.
alter table public.team_members
    add column added_by uuid references auth.users(id) on delete set null;

create or replace function public.add_team_member(p_team uuid, p_user uuid, p_role text default 'member')
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    if p_role not in ('lead', 'member') then
        raise exception 'unknown role' using errcode = '22023';
    end if;
    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    -- Administering a team is not the same act as being in one. Everything a
    -- team can read follows from membership, so choosing your own membership is
    -- choosing what you may read.
    if p_user = auth.uid() then
        raise exception 'somebody else has to add you to a team'
            using errcode = '42501';
    end if;

    if not public._is_org_member_of(v_org, p_user) then
        raise exception 'that person is not in this organization' using errcode = '42501';
    end if;

    insert into public.team_members (team_id, user_id, role, added_by)
    values (p_team, p_user, p_role, auth.uid())
    on conflict (team_id, user_id) do update
        set role = excluded.role, added_by = excluded.added_by;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'team.member_added', 'team', p_team, jsonb_build_object('user_id', p_user, 'role', p_role));
end;
$$;
