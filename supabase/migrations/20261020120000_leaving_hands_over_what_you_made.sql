-- Deleting an account failed for anyone who ever created an organization or a
-- team. `organizations.created_by` and `teams.created_by` reference auth.users
-- ON DELETE RESTRICT, and both are only ever soft-deleted, so the row outlived
-- the person who made it and `auth.admin.deleteUser` came back with an error.
--
-- `release_what_a_user_made` runs from the `delete-account` Edge Function just
-- before the auth user is deleted, in one transaction:
--
--   * an organization passes to another of its members: an active owner, else
--     an active admin, else an active member, else (a closed organization,
--     whose members `delete_organization` deprovisioned but whose content it
--     kept) a former member, most senior role first and most recent within it.
--     Nobody is promoted: `created_by` is provenance, not a role, and changing
--     who runs an organization is not a technical migration's call. A live
--     workspace subscription the departing person paid for is returned to be
--     cancelled at the end of its billing period, so colleagues keep what was
--     paid for while the erased card is not billed again; one a closed
--     organization still carries is cancelled at once;
--   * an organization with no other member row at all is hard-deleted. Content
--     tables reference organizations with NO ACTION and their `org_id` is
--     immutable once set (the `stamp_org_id` triggers), so it cannot be nulled.
--     The departing person's own rows go first — the auth delete would cascade
--     them a moment later anyway. Should anyone else's row still point at it,
--     the whole call stops with `org_has_member_data` and nothing changes.
--     Otherwise the deletion commits with the rest, before the auth delete, so
--     the person's content in that organization is gone even if the auth
--     delete then fails;
--   * a team passes to another lead who is still an active member, else to an
--     active owner or admin of its organization, else to another of its members
--     who is still active in the organization, else to any active member of the
--     organization (owner, admin, member, then the most recent), else it is
--     deleted (everything referencing a team cascades or is set null). A closed
--     organization's teams usually end here, taking their historical shares
--     and grants.
--
-- Returns what the Edge Function still has to clean up outside Postgres: each
-- deleted organization's id (its logos live under `<org id>/` in the `org-logos`
-- bucket) and every live Paddle subscription to cancel.
--
-- Additive: one new function, granted to the service role only. No table,
-- constraint or existing function changes, so every released client is
-- unaffected; an Edge Function build that predates this never calls it.

create function public.release_what_a_user_made(p_user uuid)
    returns jsonb
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org            record;
    v_team           record;
    v_fk             record;
    v_heir           uuid;
    v_subscription   text;
    v_deleted_orgs   jsonb   := '[]'::jsonb;
    v_cancel         jsonb   := '[]'::jsonb;
    v_handed_orgs    integer := 0;
    v_handed_teams   integer := 0;
    v_deleted_teams  integer := 0;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'service role required' using errcode = '42501';
    end if;
    if p_user is null then
        raise exception 'p_user is required' using errcode = '22004';
    end if;

    for v_org in
        select o.id, o.name, o.logo_path, o.deleted_at
          from public.organizations o
         where o.created_by = p_user
         order by o.created_at, o.id
           for update
    loop
        select m.user_id into v_heir
          from public.org_members m
         where m.org_id = v_org.id
           and m.user_id <> p_user
         order by (m.status = 'active') desc,
                  case m.role when 'owner' then 0 when 'admin' then 1 else 2 end,
                  case when m.status = 'active' then m.joined_at end asc,
                  m.joined_at desc,
                  m.id
         limit 1;

        if v_heir is not null then
            update public.organizations set created_by = v_heir where id = v_org.id;
            v_handed_orgs := v_handed_orgs + 1;

            select s.paddle_subscription_id into v_subscription
              from public.org_subscriptions s
             where s.org_id = v_org.id
               and s.paddle_subscription_id is not null
               and s.status not in ('canceled', 'expired')
               and (s.purchased_by = p_user or v_org.deleted_at is not null);
            if v_subscription is not null then
                v_cancel := v_cancel || jsonb_build_object(
                    'org_id', v_org.id,
                    'paddle_subscription_id', v_subscription,
                    'effective_from',
                    case when v_org.deleted_at is null then 'next_billing_period' else 'immediately' end
                );
            end if;
            continue;
        end if;

        -- Read from the catalog rather than listed by hand, so a content table
        -- added later is covered without editing this function.
        for v_fk in
            select c.conrelid::regclass as tbl, a.attname as col
              from pg_catalog.pg_constraint c
              join pg_catalog.pg_attribute a
                on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
             where c.contype = 'f'
               and c.confrelid = 'public.organizations'::regclass
               and c.confdeltype in ('a', 'r')
               and cardinality(c.conkey) = 1
               and exists (
                   select 1 from pg_catalog.pg_attribute u
                    where u.attrelid = c.conrelid
                      and u.attname = 'user_id'
                      and not u.attisdropped
               )
        loop
            execute format('delete from %s where %I = $1 and user_id = $2', v_fk.tbl, v_fk.col)
                using v_org.id, p_user;
        end loop;

        select s.paddle_subscription_id into v_subscription
          from public.org_subscriptions s
         where s.org_id = v_org.id
           and s.paddle_subscription_id is not null
           and s.status not in ('canceled', 'expired');

        begin
            delete from public.organizations where id = v_org.id;
        exception when foreign_key_violation then
            raise exception 'organization % still holds other members'' data', v_org.id
                using errcode = 'P0001',
                      hint = 'org_has_member_data',
                      detail = v_org.name;
        end;

        v_deleted_orgs := v_deleted_orgs || jsonb_build_object(
            'id', v_org.id,
            'logo_path', v_org.logo_path,
            'paddle_subscription_id', v_subscription
        );
    end loop;

    for v_team in
        select t.id, t.org_id
          from public.teams t
         where t.created_by = p_user
         order by t.created_at, t.id
           for update
    loop
        select tm.user_id into v_heir
          from public.team_members tm
          join public.org_members m
            on m.org_id = v_team.org_id and m.user_id = tm.user_id and m.status = 'active'
         where tm.team_id = v_team.id
           and tm.user_id <> p_user
           and tm.role = 'lead'
         order by tm.joined_at, tm.id
         limit 1;

        if v_heir is null then
            select m.user_id into v_heir
              from public.org_members m
             where m.org_id = v_team.org_id
               and m.user_id <> p_user
               and m.status = 'active'
               and m.role in ('owner', 'admin')
             order by (m.role = 'owner') desc, m.joined_at, m.id
             limit 1;
        end if;

        if v_heir is null then
            select tm.user_id into v_heir
              from public.team_members tm
              join public.org_members m
                on m.org_id = v_team.org_id and m.user_id = tm.user_id and m.status = 'active'
             where tm.team_id = v_team.id
               and tm.user_id <> p_user
             order by tm.joined_at, tm.id
             limit 1;
        end if;

        if v_heir is null then
            select m.user_id into v_heir
              from public.org_members m
             where m.org_id = v_team.org_id
               and m.user_id <> p_user
               and m.status = 'active'
             order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end,
                      m.joined_at desc,
                      m.id
             limit 1;
        end if;

        if v_heir is not null then
            update public.teams set created_by = v_heir where id = v_team.id;
            v_handed_teams := v_handed_teams + 1;
        else
            delete from public.teams where id = v_team.id;
            v_deleted_teams := v_deleted_teams + 1;
        end if;
    end loop;

    return jsonb_build_object(
        'deleted_orgs', v_deleted_orgs,
        'cancel_subscriptions', v_cancel,
        'handed_over_orgs', v_handed_orgs,
        'handed_over_teams', v_handed_teams,
        'deleted_teams', v_deleted_teams
    );
end;
$$;

revoke all on function public.release_what_a_user_made(uuid) from public, anon, authenticated;
grant execute on function public.release_what_a_user_made(uuid) to service_role;
