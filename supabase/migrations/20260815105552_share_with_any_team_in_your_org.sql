-- Sharing with a team requires being in the organization, not in the team.
--
-- The original rule asked for team membership, reasoning that sharing into a
-- team you are not in would be publishing to strangers. They are not strangers:
-- they are colleagues in an organization you both belong to, and the person most
-- likely to want this is the owner who created the team and put people in it.
-- Under the old rule that owner could do everything to a team except share a
-- folder with it, which reads as a bug from every angle except the one it was
-- written from.
--
-- The boundary that matters is the organization. Anything narrower stops the
-- people who administer a company from handing their own work to it.
--
-- Nothing about who can *read* changes — that is still `can_read_folder`, still
-- the team's own members, still requiring their organization membership to be
-- active.

create or replace function public.share_folder(p_label uuid, p_team uuid default null, p_org uuid default null)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_share uuid;
    v_org   uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if num_nonnulls(p_team, p_org) <> 1 then
        raise exception 'share with exactly one team or organization' using errcode = '22023';
    end if;
    if not exists (select 1 from public.labels where id = p_label and user_id = auth.uid()) then
        raise exception 'that folder is not yours to share' using errcode = '42501';
    end if;

    if p_team is not null then
        select org_id into v_org from public.teams where id = p_team and deleted_at is null;
        if v_org is null then
            raise exception 'no such team' using errcode = '42704';
        end if;
        if not public.is_org_member(v_org) then
            raise exception 'that team is not in an organization you belong to' using errcode = '42501';
        end if;
    else
        if not public.is_org_member(p_org) then
            raise exception 'you are not in that organization' using errcode = '42501';
        end if;
        v_org := p_org;
    end if;

    insert into public.folder_shares (label_id, team_id, org_id, shared_by)
    values (p_label, p_team, p_org, auth.uid())
    on conflict do nothing
    returning id into v_share;

    if v_share is null then
        select id into v_share from public.folder_shares
         where label_id = p_label
           and team_id is not distinct from p_team
           and org_id is not distinct from p_org;
    end if;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'folder.shared', 'label', p_label,
            jsonb_build_object('team_id', p_team, 'org_id', p_org));

    return v_share;
end;
$$;
