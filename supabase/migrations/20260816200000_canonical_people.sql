-- A person, as something other than a name in a sentence.
--
-- Everything Nod knows about a human being today is either the signed-in
-- account or a string: `meetings.speaker_names` holds `{"1": "Andy"}`, and an
-- action item says "ask Sam" inside its own text. That was right while the
-- product was one person's. It stops being right the moment Nod files work in a
-- colleague's name — a tracker wants an identifier, every tracker wants a
-- different one, and "Sam" is not an answer to either.
--
-- Scoped to an organization, and that is the whole security model rather than a
-- filter to remember. A person outside an organization has nobody who could see
-- them, so none is created: an account that never joins anything writes not one
-- row here, and every policy below evaluates false for it. This lands dark, the
-- same way `20260814111629` did.
--
-- `user_id` is nullable on purpose. The person a task is assigned to may have
-- never installed Nod — they are in Linear, not here — and a model that could
-- only name Nod accounts could not express the most ordinary assignment there
-- is. Nothing about a person requires them to be a user.
--
-- Deliberately absent: anything derived from a voice. Recognising a speaker by
-- voice print is a biometric identifier, `privacy.md` § 3.8 says we do not
-- collect one, and inheriting that from a migration about identity is exactly
-- how such a promise gets broken quietly. If it is ever wanted it arrives as its
-- own decision, with its own consent.

create table public.people (
    id            uuid        primary key default gen_random_uuid(),
    org_id        uuid        not null references public.organizations(id) on delete cascade,
    -- Present when this person has a Nod account in this organization. Absent
    -- for a colleague we know only from a connected tool.
    user_id       uuid        references auth.users(id) on delete set null,
    display_name  text,
    primary_email text,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    -- People are not deleted when they leave. Asked next year who committed to
    -- what last March, a removed row answers nothing — the same reasoning that
    -- made `org_members.status` a state rather than a delete.
    deleted_at    timestamptz,
    -- A plain constraint rather than a partial index because the membership sync
    -- below needs it as an `on conflict` arbiter. Nulls are distinct in Postgres,
    -- so this still allows any number of account-less people per organization.
    unique (org_id, user_id)
);

-- One record per address per organization. Partial, so a departed person's row
-- does not block re-creating them if they come back with the same address.
create unique index people_org_email_idx
    on public.people (org_id, lower(primary_email))
    where primary_email is not null and deleted_at is null;

create index people_org_idx on public.people (org_id) where deleted_at is null;
create index people_user_idx on public.people (user_id) where user_id is not null;

-- ── Who they are elsewhere ──────────────────────────────────────────────────
--
-- The list of providers is wider than `integration_connections` accepts on
-- purpose. A value here costs nothing and is not a claim that the adapter
-- exists; leaving it out would mean a migration on the day one does.
--
-- `email` is a provider like any other. It is how nearly every match is made in
-- practice, and giving it the same shape as the rest means the resolver has one
-- lookup instead of a special case.
create table public.person_identities (
    id          uuid        primary key default gen_random_uuid(),
    person_id   uuid        not null references public.people(id) on delete cascade,
    -- Copied from the parent by trigger, never accepted from a caller. It is
    -- what makes "one identity belongs to one person" enforceable per tenant.
    org_id      uuid        references public.organizations(id),
    provider    text        not null check (provider in ('email', 'linear', 'slack', 'google-calendar', 'github', 'jira')),
    -- The provider's own stable id. For `email`, the address.
    external_id text        not null,
    -- What a human reads: @alex, alex@company.com. Never used for matching —
    -- handles are renamed and ids are not.
    handle      text,
    confidence  numeric(3, 2) not null default 1.0 check (confidence between 0 and 1),
    source      text        not null check (source in ('email_match', 'user_confirmed', 'provider_directory')),
    verified_at timestamptz,
    created_at  timestamptz not null default now()
);

-- The invariant that makes resolution safe: inside one organization an external
-- identity points at exactly one person. Without it two `people` rows could both
-- claim the same Linear account and an assignment would pick whichever sorted
-- first.
create unique index person_identities_unique_idx
    on public.person_identities (org_id, provider, external_id);

create index person_identities_person_idx on public.person_identities (person_id);

-- Reusing the trigger `20260814112951` already installed on eight content
-- tables. It copies the parent's `org_id`, discards whatever arrived, and
-- refuses to let it change afterwards — which is exactly the contract wanted
-- here, and a second implementation of it would be a second thing to keep true.
create trigger stamp_org_id before insert or update of org_id on public.person_identities
    for each row execute function public._stamp_org_id_from_parent('people', 'person_id');

-- ── Membership creates the person ───────────────────────────────────────────
--
-- The only writer in this migration. A member of an organization is a person in
-- it by definition, so nothing asks and nothing has to remember to.

create function public._sync_person_from_membership()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_email  text;
    v_name   text;
    v_person uuid;
begin
    select lower(u.email), nullif(btrim(p.display_name), '')
      into v_email, v_name
      from auth.users u
      left join public.profiles p on p.user_id = u.id
     where u.id = new.user_id;

    -- Somebody already known from a connected tool, now signing in. Adopted
    -- rather than duplicated: two rows for one colleague is how an assignment
    -- lands on the copy nobody is looking at.
    update public.people
       set user_id      = new.user_id,
           display_name = coalesce(v_name, display_name),
           updated_at   = now()
     where org_id = new.org_id
       and user_id is null
       and deleted_at is null
       and primary_email = v_email
    returning id into v_person;

    if v_person is null then
        insert into public.people as p (org_id, user_id, display_name, primary_email)
        values (new.org_id, new.user_id, v_name, v_email)
        on conflict (org_id, user_id) do update
           set display_name  = coalesce(excluded.display_name, p.display_name),
               primary_email = coalesce(excluded.primary_email, p.primary_email),
               updated_at    = now()
        returning p.id into v_person;
    end if;

    if v_email is not null then
        insert into public.person_identities (person_id, provider, external_id, handle, source, verified_at)
        values (v_person, 'email', v_email, v_email, 'provider_directory', now())
        on conflict (org_id, provider, external_id) do nothing;
    end if;

    return null;
end;
$$;

revoke all on function public._sync_person_from_membership() from public, anon, authenticated;

create trigger sync_person after insert or update on public.org_members
    for each row execute function public._sync_person_from_membership();

-- A display name is edited in one place and read in five. Kept in step by
-- trigger rather than by a join, because `people` has to answer for colleagues
-- who have no `profiles` row at all and a join would make those two different
-- read paths.
create function public._sync_person_display_name()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    update public.people
       set display_name = nullif(btrim(new.display_name), ''),
           updated_at   = now()
     where user_id = new.user_id;
    return null;
end;
$$;

revoke all on function public._sync_person_display_name() from public, anon, authenticated;

create trigger sync_person_display_name after update of display_name on public.profiles
    for each row execute function public._sync_person_display_name();

-- Everybody who is already a member. The trigger only fires on writes, and the
-- organizations that exist today were populated before it existed.
insert into public.people (org_id, user_id, display_name, primary_email)
select m.org_id, m.user_id, nullif(btrim(p.display_name), ''), lower(u.email)
  from public.org_members m
  join auth.users u on u.id = m.user_id
  left join public.profiles p on p.user_id = m.user_id
on conflict (org_id, user_id) do nothing;

insert into public.person_identities (person_id, provider, external_id, handle, source, verified_at)
select pe.id, 'email', pe.primary_email, pe.primary_email, 'provider_directory', now()
  from public.people pe
 where pe.primary_email is not null
on conflict (org_id, provider, external_id) do nothing;

-- ── Reading ─────────────────────────────────────────────────────────────────
--
-- Members read their own organization's people, and nobody writes from a
-- client. Same shape as `org_members`: the roster is not a secret inside a
-- company, and `org_directory` already hands every member their colleagues'
-- addresses (`20260816130000`), so this reveals nothing that was not already
-- reachable.

alter table public.people enable row level security;
alter table public.person_identities enable row level security;

create policy "members read people in their organizations"
    on public.people for select to authenticated
    using (deleted_at is null and (select public.is_org_member(org_id)));

create policy "members read identities in their organizations"
    on public.person_identities for select to authenticated
    using (org_id is not null and (select public.is_org_member(org_id)));

grant select on table public.people to authenticated;
grant select on table public.person_identities to authenticated;

-- The provider directories are read server-side — a client that could write an
-- identity row could point a colleague's name at its own Linear account.
grant select, insert, update on table public.people to service_role;
grant select, insert, update, delete on table public.person_identities to service_role;

-- ── The directory, now answering with a person ──────────────────────────────
--
-- Same three fields as before plus the person id, so a caller that has one can
-- stop carrying a name around. Dropped and recreated because the return type
-- changes; the added column is ignored by clients that do not know it.
--
-- Still only people who have an account. A shipped build decodes `user_id` as
-- required, and handing it null would break the chat's roster on every version
-- already in the field. People without accounts reach the UI through their own
-- function when there is something to show them in.
drop function if exists public.org_directory();

create function public.org_directory()
    returns table (person_id uuid, user_id uuid, display_name text, email text)
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
declare
    v_caller uuid := auth.uid();
    v_org uuid;
begin
    if v_caller is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select p.active_org_id into v_org
      from public.profiles p
     where p.user_id = v_caller;
    if v_org is null then
        return;
    end if;
    if not exists (
        select 1 from public.org_members m
         where m.org_id = v_org and m.user_id = v_caller and m.status = 'active'
    ) then
        return;
    end if;

    return query
        select pe.id,
               pe.user_id,
               pe.display_name,
               pe.primary_email
          from public.people pe
          join public.org_members m
            on m.org_id = pe.org_id and m.user_id = pe.user_id and m.status = 'active'
         where pe.org_id = v_org
           and pe.user_id is not null
           and pe.deleted_at is null
         order by pe.display_name, pe.primary_email;
end;
$$;

revoke all on function public.org_directory() from public, anon;
grant execute on function public.org_directory() to authenticated;
