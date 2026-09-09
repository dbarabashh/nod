-- Sharing one meeting, with a team or an organization.
--
-- Folders answered "share the work I file under this heading". They cannot
-- answer the thing that happens right after a recording stops: this particular
-- call should be readable by the people it concerned, and it belongs to no
-- folder because nobody has filed it yet. Asking the host to make a folder first
-- turns a one-tap decision into housekeeping, and housekeeping does not get done
-- in the ten seconds after a call ends.
--
-- The audience is a team or the organization, never a person. That is the whole
-- correction: "who was listening" is an accident of who joined a room, while
-- "which team should see this" is a statement about the company. A share made in
-- the first vocabulary decays the moment somebody joins or leaves; one made in
-- the second keeps meaning what it meant. It also means a listener gets nothing
-- for having listened — they get it for being on the team the host chose.
--
-- Everything below mirrors `folder_shares` deliberately: same one-audience
-- constraint, same active-membership requirement, same contentless poke, same
-- audit rows. Two sharing mechanisms that answer the same question differently
-- would be the actual risk here.
--
-- Named `meeting_grants` rather than the obvious `meeting_shares`, which is
-- already the public share-link table from `20260608120000_meeting_shares.sql` —
-- a different mechanism with a different audience (anyone holding a token,
-- summary only) that must not be confused with this one at a glance.
--
-- What a shared meeting does NOT carry, matching the folder overlay exactly:
-- `screen_observations` (blocked by its own restrictive rule), `chat_messages`
-- (what you asked a meeting privately is margin notes, not the meeting), and
-- `meeting_labels` (which folder the host filed it under is their filing, not
-- part of the meeting).

create table public.meeting_grants (
    id         uuid        primary key default gen_random_uuid(),
    meeting_id uuid        not null references public.meetings(id) on delete cascade,
    team_id    uuid        references public.teams(id) on delete cascade,
    org_id     uuid        references public.organizations(id) on delete cascade,
    shared_by  uuid        not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    constraint meeting_grants_one_audience check (num_nonnulls(team_id, org_id) = 1)
);

create unique index meeting_grants_team_idx on public.meeting_grants (meeting_id, team_id) where team_id is not null;
create unique index meeting_grants_org_idx  on public.meeting_grants (meeting_id, org_id)  where org_id  is not null;
create index meeting_grants_meeting_idx on public.meeting_grants (meeting_id);

alter table public.meeting_grants enable row level security;

-- ── Reach ───────────────────────────────────────────────────────────────────

-- SECURITY DEFINER for the same reason `can_read_folder` is: it reads
-- `team_members` and `org_members`, both policed, and a policy that consults a
-- policed table to decide is a loop.
--
-- Team membership alone is not enough — organization standing has to be active,
-- so that a `team_members` row surviving some future cleanup path cannot keep
-- handing recordings to somebody who has left the company.
create function public.can_read_meeting_via_grant(p_meeting uuid)
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
              (ms.team_id is not null and exists (
                  select 1
                  from public.team_members tm
                  join public.teams t on t.id = tm.team_id and t.deleted_at is null
                  join public.org_members om
                    on om.org_id = t.org_id and om.user_id = tm.user_id and om.status = 'active'
                  where tm.team_id = ms.team_id and tm.user_id = auth.uid()
              ))
              or
              (ms.org_id is not null and exists (
                  select 1 from public.org_members om
                  where om.org_id = ms.org_id and om.user_id = auth.uid() and om.status = 'active'
              ))
          )
    );
$$;

revoke all on function public.can_read_meeting_via_grant(uuid) from public, anon;
grant execute on function public.can_read_meeting_via_grant(uuid) to authenticated;

-- ── The overlay ─────────────────────────────────────────────────────────────

-- Additive: every policy here is PERMISSIVE, so it can only widen, and each one
-- evaluates false until a `meeting_grants` row exists. Solo behaviour is
-- unchanged while the table is empty.
create policy "members read meetings shared directly"
    on public.meetings for select to authenticated
    using (deleted_at is null and (select public.can_read_meeting_via_grant(id)));

create policy "members read transcripts shared directly"
    on public.meeting_transcripts for select to authenticated
    using ((select public.can_read_meeting_via_grant(meeting_id)));

create policy "members read action items shared directly"
    on public.action_items for select to authenticated
    using (meeting_id is not null and (select public.can_read_meeting_via_grant(meeting_id)));

-- Reachable on purpose, same reasoning as the folder overlay: a shared meeting
-- whose index stayed private returns nothing to the people it was shared with,
-- and search that silently fails is worse than search that is absent.
create policy "members read embeddings shared directly"
    on public.session_embeddings for select to authenticated
    using ((select public.can_read_meeting_via_grant(meeting_id)));

create policy "audience reads its meeting shares"
    on public.meeting_grants for select to authenticated
    using ((select public.can_read_meeting_via_grant(meeting_id)));

create policy "owners read their meeting shares"
    on public.meeting_grants for select to authenticated
    using (exists (
        select 1 from public.meetings m where m.id = meeting_id and m.user_id = auth.uid()
    ));

grant select on table public.meeting_grants to authenticated;

-- ── Sharing and unsharing ───────────────────────────────────────────────────

create function public.grant_meeting(p_meeting uuid, p_team uuid default null, p_org uuid default null)
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
    if not exists (
        select 1 from public.meetings
         where id = p_meeting and user_id = auth.uid() and deleted_at is null
    ) then
        raise exception 'that meeting is not yours to share' using errcode = '42501';
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

    insert into public.meeting_grants (meeting_id, team_id, org_id, shared_by)
    values (p_meeting, p_team, p_org, auth.uid())
    on conflict do nothing
    returning id into v_share;

    if v_share is null then
        select id into v_share from public.meeting_grants
         where meeting_id = p_meeting
           and team_id is not distinct from p_team
           and org_id is not distinct from p_org;
    end if;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id, metadata)
    values (v_org, auth.uid(), 'meeting.shared', 'meeting', p_meeting,
            jsonb_build_object('team_id', p_team, 'org_id', p_org));

    return v_share;
end;
$$;

create function public.revoke_meeting_grant(p_share uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_meeting uuid;
    v_org     uuid;
begin
    select ms.meeting_id, coalesce(ms.org_id, t.org_id)
      into v_meeting, v_org
      from public.meeting_grants ms
      left join public.teams t on t.id = ms.team_id
     where ms.id = p_share;
    if v_meeting is null then
        raise exception 'no such share' using errcode = '42704';
    end if;
    if not exists (select 1 from public.meetings where id = v_meeting and user_id = auth.uid()) then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;

    delete from public.meeting_grants where id = p_share;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, auth.uid(), 'meeting.unshared', 'meeting', v_meeting);
end;
$$;

revoke all on function public.grant_meeting(uuid, uuid, uuid) from public, anon;
revoke all on function public.revoke_meeting_grant(uuid) from public, anon;
grant execute on function public.grant_meeting(uuid, uuid, uuid) to authenticated;
grant execute on function public.revoke_meeting_grant(uuid) to authenticated;

-- ── Telling the audience ────────────────────────────────────────────────────

create function public._broadcast_meeting_grant_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.meeting_grants := coalesce(new, old);
begin
    if v_row.team_id is not null then
        perform public._notify_access_changed('team:' || v_row.team_id::text);
    else
        perform public._notify_access_changed('org:' || v_row.org_id::text);
    end if;
    return null;
end;
$$;

revoke all on function public._broadcast_meeting_grant_change() from public, anon, authenticated;

create trigger broadcast_access after insert or delete on public.meeting_grants
    for each row execute function public._broadcast_meeting_grant_change();
