-- Organizations and teams: the layer an employer can be given control of.
--
-- This lands dark. Nothing reads it yet, no existing row gains a column, and no
-- existing policy is touched — solo behaviour stays byte-identical because every
-- table here is new and empty. What follows in later work (`org_id` stamped on
-- content, an admin read overlay) is additive on top of this, never a rewrite of
-- the `auth.uid() = user_id` policies the product runs on today.
--
-- Two levels, not one. A company of any size buys once and then splits into
-- teams that share nothing but the contract: one team's Linear board is not
-- another's, and the person who administers the org is usually not the person
-- who administers a team. A flat membership list cannot express that, and
-- retrofitting the level later means moving every row that points at it.
--
-- Writes are deliberately absent from the client's reach. `authenticated` gets
-- SELECT and nothing else; membership, invites and policy rows are written only
-- by SECURITY DEFINER functions that check the caller first. A client that could
-- INSERT its own `org_members` row could join any organization it learned the id
-- of, and organization ids are not secret.

-- ── Organizations ───────────────────────────────────────────────────────────

create table public.organizations (
    id         uuid        primary key default gen_random_uuid(),
    name       text        not null check (length(btrim(name)) between 1 and 120),
    slug       text        not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
    created_by uuid        not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    deleted_at timestamptz
);

-- Everything an organization can decide about itself, in one row per org so a
-- single read answers "what is this employer allowed to expect".
--
-- `allow_personal_context` is the one that is not a preference. With it off, a
-- member working inside this organization cannot route a recording to their
-- private space — the boundary stops being the user's to draw. That is the
-- control a security review asks for, and it only means anything if the server
-- owns it.
create table public.org_policies (
    org_id                 uuid        primary key references public.organizations(id) on delete cascade,
    retention_days         integer     check (retention_days is null or retention_days between 1 and 3650),
    allow_personal_context boolean     not null default true,
    allow_external_share   boolean     not null default true,
    sso_enforced           boolean     not null default false,
    sso_session_max_age    interval    not null default interval '24 hours',
    -- A vault secret *name*, never a key. Nothing in this schema stores a
    -- credential, so a leak of the whole table leaks no access.
    llm_endpoint           text,
    llm_key_ref            text,
    updated_at             timestamptz not null default now()
);

-- Surrogate key rather than `(org_id, user_id)`, and the same below for
-- `team_members`. Linking an enterprise IdP mints a *second* account for an
-- address that already signed up — Supabase refuses to link SSO identities to
-- existing users on purpose — so the two have to be merged, and a merge
-- repoints `user_id` across every table that carries it. A composite primary key
-- turns "both accounts were in this organization" into a constraint violation
-- that aborts the merge, which is precisely the case a merge exists to handle.
create table public.org_members (
    id        uuid        primary key default gen_random_uuid(),
    org_id    uuid        not null references public.organizations(id) on delete cascade,
    user_id   uuid        not null references auth.users(id) on delete cascade,
    role      text        not null default 'member' check (role in ('owner', 'admin', 'member')),
    -- `deprovisioned` is not a delete. Asked in a year who had access to a
    -- meeting last March, a removed row answers nothing.
    status    text        not null default 'active' check (status in ('active', 'suspended', 'deprovisioned')),
    -- Break-glass for enforced SSO. An identity provider's certificate expires
    -- on a schedule someone eventually misses, and an organization whose every
    -- member is locked out of the only account that could fix it is not
    -- recoverable from inside the product.
    sso_exempt boolean    not null default false,
    joined_at timestamptz not null default now(),
    unique (org_id, user_id)
);

create index org_members_user_idx on public.org_members (user_id) where status = 'active';

create table public.teams (
    id         uuid        primary key default gen_random_uuid(),
    org_id     uuid        not null references public.organizations(id) on delete cascade,
    name       text        not null check (length(btrim(name)) between 1 and 120),
    created_by uuid        not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    deleted_at timestamptz,
    unique (org_id, name)
);

create table public.team_members (
    id        uuid        primary key default gen_random_uuid(),
    team_id   uuid        not null references public.teams(id) on delete cascade,
    user_id   uuid        not null references auth.users(id) on delete cascade,
    role      text        not null default 'member' check (role in ('lead', 'member')),
    joined_at timestamptz not null default now(),
    unique (team_id, user_id)
);

create index team_members_user_idx on public.team_members (user_id);

create table public.org_invites (
    id          uuid        primary key default gen_random_uuid(),
    org_id      uuid        not null references public.organizations(id) on delete cascade,
    email       text        not null check (position('@' in email) > 1),
    role        text        not null default 'member' check (role in ('owner', 'admin', 'member')),
    team_id     uuid        references public.teams(id) on delete set null,
    token       uuid        not null unique default gen_random_uuid(),
    invited_by  uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default now() + interval '14 days',
    accepted_at timestamptz,
    accepted_by uuid        references auth.users(id) on delete set null,
    revoked_at  timestamptz
);

-- One live invite per address per organization. Re-inviting is expected; two
-- open invites for the same person, landing them in different teams depending on
-- which link they click, is not.
create unique index org_invites_pending_idx
    on public.org_invites (org_id, lower(email))
    where accepted_at is null and revoked_at is null;

-- Who did what, kept for the organization rather than for us. This is the first
-- artefact a vendor security review asks to see, and it is worth nothing if it
-- is written only when someone remembers to.
create table public.audit_log (
    id            bigint      generated always as identity primary key,
    org_id        uuid        not null references public.organizations(id) on delete cascade,
    actor_user_id uuid        references auth.users(id) on delete set null,
    action        text        not null,
    target_type   text,
    target_id     uuid,
    metadata      jsonb,
    at            timestamptz not null default now()
);

create index audit_log_org_at_idx on public.audit_log (org_id, at desc);

-- Which context a member is working in. Null is the personal one, which is what
-- every account has today and what every account keeps until it joins something.
alter table public.profiles
    add column active_org_id uuid references public.organizations(id) on delete set null;

-- ── Authorization helpers ───────────────────────────────────────────────────
--
-- Every one of these answers about the *caller* and takes no user argument.
-- That is a deliberate narrowing: a predicate that accepted a user id would let
-- any member enumerate who else belongs to an organization by calling it in a
-- loop, and none of the policies below need to ask about anyone but the caller.
--
-- SECURITY DEFINER because `org_members` has RLS of its own, and a policy on
-- `org_members` that reads `org_members` to decide is infinite recursion.

create function public.is_org_member(p_org uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1 from public.org_members
        where org_id = p_org and user_id = auth.uid() and status = 'active'
    );
$$;

create function public.is_org_admin(p_org uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1 from public.org_members
        where org_id = p_org and user_id = auth.uid()
          and status = 'active' and role in ('owner', 'admin')
    );
$$;

create function public.is_team_member(p_team uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
        from public.team_members tm
        join public.teams t on t.id = tm.team_id
        join public.org_members om
          on om.org_id = t.org_id and om.user_id = tm.user_id and om.status = 'active'
        where tm.team_id = p_team and tm.user_id = auth.uid() and t.deleted_at is null
    );
$$;

revoke all on function public.is_org_member(uuid) from public, anon;
revoke all on function public.is_org_admin(uuid) from public, anon;
revoke all on function public.is_team_member(uuid) from public, anon;
grant execute on function public.is_org_member(uuid) to authenticated;
grant execute on function public.is_org_admin(uuid) to authenticated;
grant execute on function public.is_team_member(uuid) to authenticated;

-- ── Creating an organization ────────────────────────────────────────────────
--
-- The only write `authenticated` can perform against any of this, and it exists
-- because the alternative — an INSERT policy on `organizations` plus another on
-- `org_members` — cannot make "the creator is the owner" atomic. An org with no
-- owner is an org nobody can administer.

create function public.create_organization(p_name text, p_slug text)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user uuid := auth.uid();
    v_org  uuid;
begin
    if v_user is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    insert into public.organizations (name, slug, created_by)
    values (btrim(p_name), lower(btrim(p_slug)), v_user)
    returning id into v_org;

    insert into public.org_members (org_id, user_id, role, sso_exempt)
    values (v_org, v_user, 'owner', true);

    insert into public.org_policies (org_id) values (v_org);

    insert into public.audit_log (org_id, actor_user_id, action, target_type, target_id)
    values (v_org, v_user, 'organization.created', 'organization', v_org);

    return v_org;
end;
$$;

revoke all on function public.create_organization(text, text) from public, anon;
grant execute on function public.create_organization(text, text) to authenticated;

-- ── Row-level security ──────────────────────────────────────────────────────
--
-- Read for members, write for nobody. Every mutation beyond `create_organization`
-- arrives in later work as a SECURITY DEFINER function that authorizes its caller
-- explicitly, so these tables expose no INSERT/UPDATE/DELETE policy at all and
-- `authenticated` is granted only SELECT.

alter table public.organizations enable row level security;
alter table public.org_policies  enable row level security;
alter table public.org_members   enable row level security;
alter table public.teams         enable row level security;
alter table public.team_members  enable row level security;
alter table public.org_invites   enable row level security;
alter table public.audit_log     enable row level security;

create policy "members read their organizations"
    on public.organizations for select to authenticated
    using (deleted_at is null and (select public.is_org_member(id)));

create policy "members read their org policies"
    on public.org_policies for select to authenticated
    using ((select public.is_org_member(org_id)));

create policy "members read co-members"
    on public.org_members for select to authenticated
    using ((select public.is_org_member(org_id)));

create policy "members read org teams"
    on public.teams for select to authenticated
    using (deleted_at is null and (select public.is_org_member(org_id)));

-- Team rosters are visible org-wide on purpose: knowing which colleague is on
-- which team is not a secret inside a company, and hiding it would make the
-- "which team owns this connector" question unanswerable from the UI.
create policy "org members read team rosters"
    on public.team_members for select to authenticated
    using (exists (
        select 1 from public.teams t
        where t.id = team_id and t.deleted_at is null and (select public.is_org_admin(t.org_id) or public.is_org_member(t.org_id))
    ));

-- Invites carry an address that has not agreed to anything yet, so they stay
-- with the administrators. Acceptance happens by token, through a function.
create policy "admins read org invites"
    on public.org_invites for select to authenticated
    using ((select public.is_org_admin(org_id)));

create policy "admins read org audit log"
    on public.audit_log for select to authenticated
    using ((select public.is_org_admin(org_id)));

grant select on table public.organizations to authenticated;
grant select on table public.org_policies  to authenticated;
grant select on table public.org_members   to authenticated;
grant select on table public.teams         to authenticated;
grant select on table public.team_members  to authenticated;
grant select on table public.org_invites   to authenticated;
grant select on table public.audit_log     to authenticated;
