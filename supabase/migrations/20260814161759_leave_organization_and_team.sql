-- Leaving, as an act of your own.
--
-- Until now the only way out of an organization was `remove_org_member`, which
-- an administrator calls about somebody else. That makes joining reversible only
-- by permission — you could accept an invite in a second and then need another
-- person to undo it. Membership carries obligations in both directions, and the
-- one it puts on the member is exactly the one they should be able to end.
--
-- The last owner is the single exception, and not out of caution: an
-- organization with no owner cannot be administered, invited to, or closed, and
-- recovering it needs us. The refusal says what to do instead rather than only
-- that it refused.
--
-- What stays behind is what already belonged to the organization. `org_id` is
-- immutable by design, so sessions recorded for an employer keep pointing at
-- them — leaving ends access, it does not retract work. The person still reads
-- their own sessions under the owner policy they have always had.

create function public.leave_organization(p_org uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_role text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select role into v_role
      from public.org_members
     where org_id = p_org and user_id = auth.uid() and status = 'active';
    if v_role is null then
        raise exception 'you are not in that organization' using errcode = '42704';
    end if;

    if v_role = 'owner' and (
        select count(*) from public.org_members
         where org_id = p_org and role = 'owner' and status = 'active'
    ) <= 1 then
        raise exception
            'you are the only owner — make someone else an owner first, or delete the organization'
            using errcode = '23514';
    end if;

    update public.org_members set status = 'deprovisioned'
     where org_id = p_org and user_id = auth.uid();

    delete from public.team_members tm
     using public.teams t
     where tm.team_id = t.id and t.org_id = p_org and tm.user_id = auth.uid();

    -- Connections lose their team, not their link: the person authorised their
    -- own Linear and is walking out of a company, not out of their own tools.
    update public.integration_connections ic
       set team_id = null
      from public.teams t
     where ic.team_id = t.id and t.org_id = p_org and ic.user_id = auth.uid();

    update public.profiles set active_org_id = null
     where user_id = auth.uid() and active_org_id = p_org;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (p_org, auth.uid(), 'member.left', 'user', auth.uid());
end;
$$;

create function public.leave_team(p_team uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    if not exists (select 1 from public.team_members where team_id = p_team and user_id = auth.uid()) then
        raise exception 'you are not in that team' using errcode = '42704';
    end if;

    delete from public.team_members where team_id = p_team and user_id = auth.uid();
    update public.integration_connections
       set team_id = null
     where team_id = p_team and user_id = auth.uid();

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, auth.uid(), 'team.left', 'team', p_team);
end;
$$;

revoke all on function public.leave_organization(uuid) from public, anon;
revoke all on function public.leave_team(uuid) from public, anon;
grant execute on function public.leave_organization(uuid) to authenticated;
grant execute on function public.leave_team(uuid) to authenticated;
