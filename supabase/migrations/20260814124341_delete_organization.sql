-- Closing an organization.
--
-- The action a sole owner actually wants. Membership rules make it impossible to
-- remove yourself from an organization you are the last owner of — correctly, an
-- organization without an owner is unadministrable — which leaves closing it as
-- the only honest way out. Offering removal instead would be offering a button
-- that cannot work.
--
-- Soft, like every other delete in this schema. `organizations.deleted_at` drops
-- the row out of every policy that reads it, so members lose access at once,
-- while the audit log keeps its foreign key and can still answer who was in it.
--
-- Content stamped to the organization keeps its `org_id`. That is not an
-- oversight: `org_id` is immutable by design, and a recording made for an
-- employer does not stop having been made for them because the account closed.
-- Its author still reads it under the owner policy they have always had; nobody
-- else does, because the administrator overlay requires an active membership and
-- there are none left.

create function public.delete_organization(p_org uuid)
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

    -- Administrators run an organization; only an owner ends one.
    if v_role is distinct from 'owner' then
        raise exception 'only an owner can delete an organization' using errcode = '42501';
    end if;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (p_org, auth.uid(), 'organization.deleted', 'organization', p_org);

    update public.organizations set deleted_at = now() where id = p_org and deleted_at is null;

    update public.org_invites set revoked_at = now()
     where org_id = p_org and accepted_at is null and revoked_at is null;

    -- Everyone goes back to their personal space rather than being left pointing
    -- at something they can no longer read.
    update public.profiles set active_org_id = null where active_org_id = p_org;

    delete from public.team_members tm
     using public.teams t
     where tm.team_id = t.id and t.org_id = p_org;

    update public.teams set deleted_at = now() where org_id = p_org and deleted_at is null;

    update public.org_members set status = 'deprovisioned' where org_id = p_org;
end;
$$;

revoke all on function public.delete_organization(uuid) from public, anon;
grant execute on function public.delete_organization(uuid) to authenticated;
