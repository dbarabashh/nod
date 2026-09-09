-- Operating teams.
--
-- A team is the boundary of *people and tools*, not of content. One person sits
-- in a single team but records meetings that concern several, so filing a
-- recording under a team would ask a question with no honest answer. That is why
-- `org_id` reaches content and `team_id` does not: what gets shared is decided
-- on its own axis, by the folder a session is filed into, and who is in which
-- team decides which Linear the chat should reach for.
--
-- Membership of a team is a subset of membership of its organization, enforced
-- rather than assumed: an organization can be left while a team row survives,
-- and a stale row would otherwise keep granting a connector to somebody who
-- walked out.

create function public.create_team(p_org uuid, p_name text)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_team uuid;
begin
    perform public._assert_org_admin(p_org);

    insert into public.teams (org_id, name, created_by)
    values (p_org, btrim(p_name), auth.uid())
    returning id into v_team;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (p_org, auth.uid(), 'team.created', 'team', v_team, jsonb_build_object('name', btrim(p_name)));

    return v_team;
end;
$$;

create function public.rename_team(p_team uuid, p_name text)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    update public.teams set name = btrim(p_name) where id = p_team;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'team.renamed', 'team', p_team, jsonb_build_object('name', btrim(p_name)));
end;
$$;

create function public.delete_team(p_team uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    -- Connections lose their scope rather than their existence: the person
    -- connected their own Linear, and closing a team is no reason to unlink it.
    update public.integration_connections set team_id = null where team_id = p_team;
    delete from public.team_members where team_id = p_team;
    update public.teams set deleted_at = now() where id = p_team;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, auth.uid(), 'team.deleted', 'team', p_team);
end;
$$;

create function public.add_team_member(p_team uuid, p_user uuid, p_role text default 'member')
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

    if not public._is_org_member_of(v_org, p_user) then
        raise exception 'that person is not in this organization' using errcode = '42501';
    end if;

    insert into public.team_members (team_id, user_id, role)
    values (p_team, p_user, p_role)
    on conflict (team_id, user_id) do update set role = excluded.role;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'team.member_added', 'team', p_team, jsonb_build_object('user_id', p_user, 'role', p_role));
end;
$$;

create function public.remove_team_member(p_team uuid, p_user uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    delete from public.team_members where team_id = p_team and user_id = p_user;
    update public.integration_connections
       set team_id = null
     where team_id = p_team and user_id = p_user;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'team.member_removed', 'team', p_team, jsonb_build_object('user_id', p_user));
end;
$$;

-- Names and addresses for one team, for the pane that manages it. Administrators
-- only, matching `list_org_members` — the roster itself is readable org-wide
-- through RLS, but a list of everyone's email is a different thing to hand out.
create function public.list_team_members(p_team uuid)
    returns table (user_id uuid, email text, display_name text, role text)
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    select org_id into v_org from public.teams where id = p_team and deleted_at is null;
    if v_org is null then
        raise exception 'no such team' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    return query
        select tm.user_id, lower(u.email), nullif(btrim(p.display_name), ''), tm.role
          from public.team_members tm
          join auth.users u on u.id = tm.user_id
          left join public.profiles p on p.user_id = tm.user_id
         where tm.team_id = p_team
         order by (tm.role = 'lead') desc, lower(u.email);
end;
$$;

-- Which team a connection serves. Owned by the person who linked it — nobody
-- scopes somebody else's credential — and only to a team they are actually in.
create function public.set_integration_team(p_provider text, p_team uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_team is not null and not exists (
        select 1 from public.team_members where team_id = p_team and user_id = auth.uid()
    ) then
        raise exception 'you are not in that team' using errcode = '42501';
    end if;

    update public.integration_connections
       set team_id = p_team
     where user_id = auth.uid() and provider = p_provider and revoked_at is null;
end;
$$;

revoke all on function public.create_team(uuid, text) from public, anon;
revoke all on function public.rename_team(uuid, text) from public, anon;
revoke all on function public.delete_team(uuid) from public, anon;
revoke all on function public.add_team_member(uuid, uuid, text) from public, anon;
revoke all on function public.remove_team_member(uuid, uuid) from public, anon;
revoke all on function public.list_team_members(uuid) from public, anon;
revoke all on function public.set_integration_team(text, uuid) from public, anon;

grant execute on function public.create_team(uuid, text) to authenticated;
grant execute on function public.rename_team(uuid, text) to authenticated;
grant execute on function public.delete_team(uuid) to authenticated;
grant execute on function public.add_team_member(uuid, uuid, text) to authenticated;
grant execute on function public.remove_team_member(uuid, uuid) to authenticated;
grant execute on function public.list_team_members(uuid) to authenticated;
grant execute on function public.set_integration_team(text, uuid) to authenticated;
