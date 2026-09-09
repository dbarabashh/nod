-- Joining, leaving, and being administered.
--
-- Every write to `org_members` and `org_invites` lands here rather than through
-- a policy, because each one carries a rule a policy cannot express: an invite
-- is accepted by the address it was sent to and no other, a role is granted only
-- by someone entitled to grant it, and an organization must never be left
-- without an owner. Those are transactions, not row predicates.
--
-- Membership is never deleted. `deprovisioned` is the end state, because the
-- audit log has to be able to answer who had access last March, and a removed
-- row answers nothing.

-- ── Internal guards ─────────────────────────────────────────────────────────

create function public._assert_org_admin(p_org uuid)
    returns text
    language plpgsql
    stable
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
    if v_role is null or v_role not in ('owner', 'admin') then
        raise exception 'not an administrator of that organization' using errcode = '42501';
    end if;
    return v_role;
end;
$$;

revoke all on function public._assert_org_admin(uuid) from public, anon, authenticated;

-- The last person able to administer an organization cannot be demoted or
-- removed — by themselves or by anyone else. Recovering from that state needs
-- us, and an organization should not have to ask.
create function public._assert_not_last_owner(p_org uuid, p_user uuid)
    returns void
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
begin
    if exists (
        select 1 from public.org_members
        where org_id = p_org and user_id = p_user and role = 'owner' and status = 'active'
    ) and (
        select count(*) from public.org_members
        where org_id = p_org and role = 'owner' and status = 'active'
    ) <= 1 then
        raise exception 'an organization must keep at least one owner' using errcode = '23514';
    end if;
end;
$$;

revoke all on function public._assert_not_last_owner(uuid, uuid) from public, anon, authenticated;

-- ── Inviting ────────────────────────────────────────────────────────────────

-- Returns everything the caller needs to deliver the invite — token, the names
-- that go in the message — so sending it takes no second round trip and no
-- second set of permissions.
create function public.invite_to_organization(
    p_org uuid,
    p_email text,
    p_role text default 'member',
    p_team uuid default null
)
    returns jsonb
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_caller_role text := public._assert_org_admin(p_org);
    v_email text := lower(btrim(p_email));
    v_token uuid;
    v_org_name text;
    v_inviter text;
begin
    if position('@' in v_email) < 2 then
        raise exception 'a valid email address is required' using errcode = '22023';
    end if;
    if p_role not in ('owner', 'admin', 'member') then
        raise exception 'unknown role' using errcode = '22023';
    end if;
    -- Only an owner hands out ownership. An administrator who could would be an
    -- owner with extra steps.
    if p_role = 'owner' and v_caller_role <> 'owner' then
        raise exception 'only an owner can invite an owner' using errcode = '42501';
    end if;
    if p_team is not null and not exists (
        select 1 from public.teams where id = p_team and org_id = p_org and deleted_at is null
    ) then
        raise exception 'that team is not in this organization' using errcode = '22023';
    end if;
    if exists (
        select 1 from public.org_members m
        join auth.users u on u.id = m.user_id
        where m.org_id = p_org and m.status = 'active' and lower(u.email) = v_email
    ) then
        raise exception 'that person is already a member' using errcode = '23505';
    end if;

    -- Re-inviting replaces rather than stacks; the partial unique index allows
    -- one live invite per address per organization, and the newest terms are the
    -- ones that should apply.
    update public.org_invites
       set revoked_at = now()
     where org_id = p_org and lower(email) = v_email
       and accepted_at is null and revoked_at is null;

    insert into public.org_invites (org_id, email, role, team_id, invited_by)
    values (p_org, v_email, p_role, p_team, auth.uid())
    returning token into v_token;

    select name into v_org_name from public.organizations where id = p_org;
    select coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1))
      into v_inviter
      from auth.users u
      left join public.profiles p on p.user_id = u.id
     where u.id = auth.uid();

    insert into public.audit_log (org_id, actor_user_id, action, target_type, metadata)
    values (p_org, auth.uid(), 'invite.created', 'invite', jsonb_build_object('email', v_email, 'role', p_role));

    return jsonb_build_object(
        'token', v_token,
        'org_name', v_org_name,
        'inviter', coalesce(v_inviter, 'A teammate'),
        'role', p_role,
        'email', v_email
    );
end;
$$;

revoke all on function public.invite_to_organization(uuid, text, text, uuid) from public, anon;
grant execute on function public.invite_to_organization(uuid, text, text, uuid) to authenticated;

create function public.revoke_org_invite(p_invite uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org uuid;
begin
    select org_id into v_org from public.org_invites where id = p_invite;
    if v_org is null then
        raise exception 'no such invite' using errcode = '42704';
    end if;
    perform public._assert_org_admin(v_org);

    update public.org_invites set revoked_at = now()
     where id = p_invite and accepted_at is null and revoked_at is null;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, auth.uid(), 'invite.revoked', 'invite', p_invite);
end;
$$;

revoke all on function public.revoke_org_invite(uuid) from public, anon;
grant execute on function public.revoke_org_invite(uuid) to authenticated;

-- ── Accepting ───────────────────────────────────────────────────────────────

-- The token alone is not enough. It is delivered by email, and an email can be
-- forwarded — so acceptance also requires that the signed-in address is the one
-- invited. An organization decides who joins it; a link should not.
create function public.accept_org_invite(p_token uuid)
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
        insert into public.team_members (team_id, user_id)
        values (v_invite.team_id, auth.uid())
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

revoke all on function public.accept_org_invite(uuid) from public, anon;
grant execute on function public.accept_org_invite(uuid) to authenticated;

-- ── Administering members ───────────────────────────────────────────────────

-- Addresses, which the `org_members` table does not carry and RLS therefore
-- cannot filter. Administrators only: a roster is not a secret inside a company,
-- but a list of everyone's email is a different thing to hand out.
create function public.list_org_members(p_org uuid)
    returns table (user_id uuid, email text, display_name text, role text, status text, joined_at timestamptz)
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
begin
    perform public._assert_org_admin(p_org);
    return query
        select m.user_id, lower(u.email), nullif(btrim(p.display_name), ''), m.role, m.status, m.joined_at
          from public.org_members m
          join auth.users u on u.id = m.user_id
          left join public.profiles p on p.user_id = m.user_id
         where m.org_id = p_org
         order by (m.role = 'owner') desc, (m.role = 'admin') desc, lower(u.email);
end;
$$;

revoke all on function public.list_org_members(uuid) from public, anon;
grant execute on function public.list_org_members(uuid) to authenticated;

create function public.set_org_member_role(p_org uuid, p_user uuid, p_role text)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_caller_role text := public._assert_org_admin(p_org);
begin
    if p_role not in ('owner', 'admin', 'member') then
        raise exception 'unknown role' using errcode = '22023';
    end if;
    if v_caller_role <> 'owner' then
        raise exception 'only an owner can change roles' using errcode = '42501';
    end if;
    if p_role <> 'owner' then
        perform public._assert_not_last_owner(p_org, p_user);
    end if;

    update public.org_members set role = p_role
     where org_id = p_org and user_id = p_user and status = 'active';

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (p_org, auth.uid(), 'member.role_changed', 'user', p_user, jsonb_build_object('role', p_role));
end;
$$;

revoke all on function public.set_org_member_role(uuid, uuid, text) from public, anon;
grant execute on function public.set_org_member_role(uuid, uuid, text) to authenticated;

create function public.remove_org_member(p_org uuid, p_user uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform public._assert_org_admin(p_org);
    perform public._assert_not_last_owner(p_org, p_user);

    update public.org_members set status = 'deprovisioned'
     where org_id = p_org and user_id = p_user;

    delete from public.team_members tm
     using public.teams t
     where tm.team_id = t.id and t.org_id = p_org and tm.user_id = p_user;

    -- Their context goes back to personal so nothing new is filed to an
    -- organization they are no longer in. What they already recorded there stays
    -- there: `org_id` is immutable, and content does not leave with the person.
    update public.profiles set active_org_id = null
     where user_id = p_user and active_org_id = p_org;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (p_org, auth.uid(), 'member.removed', 'user', p_user);
end;
$$;

revoke all on function public.remove_org_member(uuid, uuid) from public, anon;
grant execute on function public.remove_org_member(uuid, uuid) to authenticated;
