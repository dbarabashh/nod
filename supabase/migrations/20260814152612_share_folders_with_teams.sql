-- Shared context: the third axis.
--
-- Organizations decide who pays and who may administer. Teams decide who works
-- together and which Linear the chat reaches for. Neither shares a recording,
-- and that was deliberate — a person sits in one team but records meetings that
-- concern several, so membership cannot decide what a colleague reads without
-- guessing.
--
-- Folders can. A folder is already a thing people make for their own sake
-- (`labels`), which is why it is the right handle: filing a session somewhere is
-- an act the person takes for their own reasons, and sharing that folder is a
-- second, separate act with an obvious meaning. Nothing becomes readable because
-- somebody joined a team.
--
-- The overlay is additive and guarded. Every policy below is PERMISSIVE, so it
-- can only widen, and every one of them evaluates false until an actual
-- `folder_shares` row exists — which means solo behaviour is unchanged and
-- byte-identical while the table is empty.
--
-- What is deliberately NOT reachable through a shared folder:
--
--   * `screen_observations` — ambient screen text, blocked by its own
--     restrictive rule, which this migration does not and cannot loosen.
--   * `chat_messages` — what you asked a meeting privately is commentary, not
--     the meeting. Sharing the room should not hand over the margin notes.
--   * `knowledge_threads` / `knowledge_messages` — cross-session chats span
--     everything you have, shared or not, so they cannot follow one folder.
--
-- `session_embeddings` IS reachable, on purpose: it is derived from the
-- transcript, and a shared session whose index stayed private would return
-- nothing to the people it was shared with — search that silently fails is worse
-- than search that is absent.

create table public.folder_shares (
    id         uuid        primary key default gen_random_uuid(),
    label_id   uuid        not null references public.labels(id) on delete cascade,
    team_id    uuid        references public.teams(id) on delete cascade,
    org_id     uuid        references public.organizations(id) on delete cascade,
    shared_by  uuid        not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    -- One audience per row. A share that named both would have two answers to
    -- "who can read this", and the wider one would always win silently.
    constraint folder_shares_one_audience check (num_nonnulls(team_id, org_id) = 1)
);

create unique index folder_shares_team_idx on public.folder_shares (label_id, team_id) where team_id is not null;
create unique index folder_shares_org_idx  on public.folder_shares (label_id, org_id)  where org_id  is not null;
create index folder_shares_label_idx on public.folder_shares (label_id);

alter table public.folder_shares enable row level security;

-- ── Reach ───────────────────────────────────────────────────────────────────

-- SECURITY DEFINER because the answer needs `folder_shares`, `team_members` and
-- `org_members` — all of which have policies of their own, and a policy that
-- reads a policed table to decide is a loop.
create function public.can_read_folder(p_label uuid)
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
                  select 1 from public.team_members tm
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

create function public.can_read_meeting_via_folder(p_meeting uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.meeting_labels ml
        where ml.meeting_id = p_meeting
          and public.can_read_folder(ml.label_id)
    );
$$;

revoke all on function public.can_read_folder(uuid) from public, anon;
revoke all on function public.can_read_meeting_via_folder(uuid) from public, anon;
grant execute on function public.can_read_folder(uuid) to authenticated;
grant execute on function public.can_read_meeting_via_folder(uuid) to authenticated;

-- ── The overlay ─────────────────────────────────────────────────────────────

create policy "members read meetings shared through a folder"
    on public.meetings for select to authenticated
    using (deleted_at is null and (select public.can_read_meeting_via_folder(id)));

create policy "members read transcripts shared through a folder"
    on public.meeting_transcripts for select to authenticated
    using ((select public.can_read_meeting_via_folder(meeting_id)));

create policy "members read action items shared through a folder"
    on public.action_items for select to authenticated
    using (meeting_id is not null and (select public.can_read_meeting_via_folder(meeting_id)));

create policy "members read embeddings shared through a folder"
    on public.session_embeddings for select to authenticated
    using ((select public.can_read_meeting_via_folder(meeting_id)));

-- The folder itself and its contents, so a shared session can be found rather
-- than only opened by someone who already had its id.
create policy "members read shared folders"
    on public.labels for select to authenticated
    using ((select public.can_read_folder(id)));

create policy "members read shared folder contents"
    on public.meeting_labels for select to authenticated
    using ((select public.can_read_folder(label_id)));

create policy "audience reads its folder shares"
    on public.folder_shares for select to authenticated
    using ((select public.can_read_folder(label_id)));

create policy "owners read their folder shares"
    on public.folder_shares for select to authenticated
    using (exists (
        select 1 from public.labels l where l.id = label_id and l.user_id = auth.uid()
    ));

grant select on table public.folder_shares to authenticated;

-- ── Sharing and unsharing ───────────────────────────────────────────────────

-- Only the person whose folder it is, and only with an audience they are part
-- of. Sharing into a team you are not in would be publishing to strangers.
create function public.share_folder(p_label uuid, p_team uuid default null, p_org uuid default null)
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
        if not exists (select 1 from public.team_members where team_id = p_team and user_id = auth.uid()) then
            raise exception 'you are not in that team' using errcode = '42501';
        end if;
        select org_id into v_org from public.teams where id = p_team;
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

create function public.unshare_folder(p_share uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_label uuid;
    v_org   uuid;
begin
    select fs.label_id, coalesce(fs.org_id, t.org_id)
      into v_label, v_org
      from public.folder_shares fs
      left join public.teams t on t.id = fs.team_id
     where fs.id = p_share;
    if v_label is null then
        raise exception 'no such share' using errcode = '42704';
    end if;
    if not exists (select 1 from public.labels where id = v_label and user_id = auth.uid()) then
        raise exception 'that folder is not yours' using errcode = '42501';
    end if;

    delete from public.folder_shares where id = p_share;

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, auth.uid(), 'folder.unshared', 'label', v_label);
end;
$$;

revoke all on function public.share_folder(uuid, uuid, uuid) from public, anon;
revoke all on function public.unshare_folder(uuid) from public, anon;
grant execute on function public.share_folder(uuid, uuid, uuid) to authenticated;
grant execute on function public.unshare_folder(uuid) to authenticated;
