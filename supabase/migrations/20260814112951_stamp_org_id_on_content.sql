-- Content learns which organization it belongs to.
--
-- Ownership does not move: a meeting still belongs to the person who recorded
-- it, and every existing `auth.uid() = user_id` policy is left exactly as it is.
-- What changes is that a row can now also answer "whose contract covers this",
-- which is the question retention, export, legal hold and admin recovery are all
-- forms of. An employer cannot be given control of data that cannot say it is
-- theirs.
--
-- Every column added here is nullable with no default, so this is a metadata
-- change on all eight tables — no rewrite, no lock worth the name, nothing moved
-- even on `meeting_transcripts` and its seventy thousand rows. Every existing
-- row keeps `org_id` null, which is what "personal" means, and every predicate
-- added below is guarded on `org_id is not null`. For an account that never
-- joins an organization, nothing in this migration ever evaluates true.
--
-- `org_id` is stamped by the database, never accepted from the client on trust.
-- Two rules, because the eight tables are two kinds:
--
--   * `meetings`, `knowledge_threads` and `screen_observations` are where a
--     person chooses a context, so their trigger validates the claim against
--     live membership.
--   * the other five hang off one of those, so their trigger *copies* the
--     parent's value and discards whatever arrived. That is both unforgeable and
--     cheap — a primary-key lookup on a row the foreign key already required —
--     which matters because `meeting_transcripts` is written once per utterance
--     while a meeting runs, and a membership query on that path would be paid
--     thousands of times per call.

alter table public.meetings            add column org_id uuid references public.organizations(id);
alter table public.knowledge_threads   add column org_id uuid references public.organizations(id);
alter table public.screen_observations add column org_id uuid references public.organizations(id);
alter table public.meeting_transcripts add column org_id uuid references public.organizations(id);
alter table public.session_embeddings  add column org_id uuid references public.organizations(id);
alter table public.chat_messages       add column org_id uuid references public.organizations(id);
alter table public.action_items        add column org_id uuid references public.organizations(id);
alter table public.knowledge_messages  add column org_id uuid references public.organizations(id);

create index meetings_org_idx            on public.meetings            (org_id) where org_id is not null;
create index knowledge_threads_org_idx   on public.knowledge_threads   (org_id) where org_id is not null;
create index screen_observations_org_idx on public.screen_observations (org_id) where org_id is not null;
create index meeting_transcripts_org_idx on public.meeting_transcripts (org_id) where org_id is not null;
create index session_embeddings_org_idx  on public.session_embeddings  (org_id) where org_id is not null;
create index chat_messages_org_idx       on public.chat_messages       (org_id) where org_id is not null;
create index action_items_org_idx        on public.action_items        (org_id) where org_id is not null;
create index knowledge_messages_org_idx  on public.knowledge_messages  (org_id) where org_id is not null;

-- Whether administrators may read what their members recorded. Off by default,
-- and deliberately its own switch rather than something `admin` implies: a
-- security review needs to hear that data can be retrieved on request, and a
-- member needs it not to be true by accident on the day they join.
alter table public.org_policies
    add column admin_content_access boolean not null default false;

-- ── Stamping ────────────────────────────────────────────────────────────────

-- Membership by explicit user rather than `auth.uid()`, because the triggers
-- below attribute a row to `NEW.user_id` and that is the identity whose claim
-- has to hold. Granted to nobody: callable only from the trigger functions,
-- which run as this function's owner. Exposing it would hand any member a way to
-- enumerate who else belongs to an organization.
create function public._is_org_member_of(p_org uuid, p_user uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1 from public.org_members
        where org_id = p_org and user_id = p_user and status = 'active'
    );
$$;

revoke all on function public._is_org_member_of(uuid, uuid) from public, anon, authenticated;

create function public._stamp_org_id_from_context()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_active  uuid;
    v_personal boolean;
begin
    -- Content does not change hands. Without this an organization's data could
    -- be moved into another one by its own owner, which is the one direction
    -- retention and legal hold cannot survive.
    if tg_op = 'UPDATE' and old.org_id is not null and new.org_id is distinct from old.org_id then
        raise exception 'org_id is immutable once set' using errcode = '42501';
    end if;

    if new.org_id is not null then
        if not public._is_org_member_of(new.org_id, new.user_id) then
            raise exception 'not a member of that organization' using errcode = '42501';
        end if;
        return new;
    end if;

    select active_org_id into v_active from public.profiles where user_id = new.user_id;
    if v_active is null then
        return new;
    end if;

    select allow_personal_context into v_personal from public.org_policies where org_id = v_active;
    -- The organization, not the member, decides whether a private context
    -- exists inside it. With it switched off, everything recorded while working
    -- there belongs there, and there is no client-side way to opt a row out.
    if v_personal is false and public._is_org_member_of(v_active, new.user_id) then
        new.org_id := v_active;
    end if;

    return new;
end;
$$;

create function public._stamp_org_id_from_parent()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_parent uuid;
    v_org    uuid;
begin
    if tg_op = 'UPDATE' and old.org_id is not null and new.org_id is distinct from old.org_id then
        raise exception 'org_id is immutable once set' using errcode = '42501';
    end if;

    v_parent := (to_jsonb(new) ->> tg_argv[1])::uuid;
    if v_parent is null then
        new.org_id := null;
        return new;
    end if;

    execute format('select org_id from public.%I where id = $1', tg_argv[0])
        into v_org using v_parent;

    -- Assigned, not merged: whatever the client sent is discarded. A child row
    -- that could name its own organization would be a way to write into one.
    new.org_id := v_org;
    return new;
end;
$$;

revoke all on function public._stamp_org_id_from_context() from public, anon, authenticated;
revoke all on function public._stamp_org_id_from_parent() from public, anon, authenticated;

create trigger stamp_org_id before insert or update of org_id on public.meetings
    for each row execute function public._stamp_org_id_from_context();
create trigger stamp_org_id before insert or update of org_id on public.knowledge_threads
    for each row execute function public._stamp_org_id_from_context();
create trigger stamp_org_id before insert or update of org_id on public.screen_observations
    for each row execute function public._stamp_org_id_from_context();

create trigger stamp_org_id before insert or update of org_id on public.meeting_transcripts
    for each row execute function public._stamp_org_id_from_parent('meetings', 'meeting_id');
create trigger stamp_org_id before insert or update of org_id on public.session_embeddings
    for each row execute function public._stamp_org_id_from_parent('meetings', 'meeting_id');
create trigger stamp_org_id before insert or update of org_id on public.chat_messages
    for each row execute function public._stamp_org_id_from_parent('meetings', 'meeting_id');
create trigger stamp_org_id before insert or update of org_id on public.action_items
    for each row execute function public._stamp_org_id_from_parent('meetings', 'meeting_id');
create trigger stamp_org_id before insert or update of org_id on public.knowledge_messages
    for each row execute function public._stamp_org_id_from_parent('knowledge_threads', 'thread_id');

-- ── Administrator read overlay ──────────────────────────────────────────────
--
-- Permissive, so Postgres ORs these with the owner policies already in place:
-- they can only widen, never take away what a person can already see. And they
-- widen nothing today — `org_id is not null` is false for every row that exists,
-- and `admin_content_access` defaults to off for every organization that will.

create function public.can_admin_read_org_content(p_org uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.org_members m
        join public.org_policies p on p.org_id = m.org_id
        where m.org_id = p_org and m.user_id = auth.uid()
          and m.status = 'active' and m.role in ('owner', 'admin')
          and p.admin_content_access
    );
$$;

revoke all on function public.can_admin_read_org_content(uuid) from public, anon;
grant execute on function public.can_admin_read_org_content(uuid) to authenticated;

create policy "org admins read org meetings"
    on public.meetings for select to authenticated
    using (org_id is not null and (select public.can_admin_read_org_content(org_id)));

create policy "org admins read org transcripts"
    on public.meeting_transcripts for select to authenticated
    using (org_id is not null and (select public.can_admin_read_org_content(org_id)));

create policy "org admins read org action items"
    on public.action_items for select to authenticated
    using (org_id is not null and (select public.can_admin_read_org_content(org_id)));

create policy "org admins read org chat messages"
    on public.chat_messages for select to authenticated
    using (org_id is not null and (select public.can_admin_read_org_content(org_id)));

-- `screen_observations`, `session_embeddings`, `knowledge_threads` and
-- `knowledge_messages` get the column and no read overlay.
--
-- The column is what retention, export and erasure need, and those are
-- obligations an organization has to meet. Reading is a separate question, and
-- for ambient screen text it is a different one: `privacy.md` § 3.10 describes a
-- capture the user switches on for themselves, excludes apps from, and sets the
-- lifetime of. An administrator browsing it would not be a wider version of that
-- promise, it would be a different promise. If it is ever wanted it should
-- arrive as its own decision, with its own switch and its own line in the
-- policy — not inherited from a migration about columns.
