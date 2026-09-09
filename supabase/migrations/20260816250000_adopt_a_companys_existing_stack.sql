-- Picking up a company as it already is.
--
-- Onboarding an organization the honest way costs somebody an afternoon: invite
-- every colleague to Nod, wait for them to accept, and only then can a meeting
-- assign work to any of them. Until that is done the product's whole point does
-- not function, and the person evaluating it has no reason to finish.
--
-- But the company already has this list. It is in whatever tracker they use and
-- whatever chat they use, it is accurate because people are removed from those
-- when they leave, and connecting one is a thing an administrator does in the
-- first minute anyway. So the roster comes from there — and a colleague becomes
-- assignable without ever installing Nod.
--
-- Which is what `people.user_id` being nullable was for (`20260816200000`). This
-- migration adds the read that can see those rows, because `org_directory()`
-- deliberately cannot: it answers with `user_id` as a required field, and every
-- shipped build decodes it as one.
--
-- The import itself is server-side and lives in `_shared/integrations/
-- directory.ts`, provider-agnostic by construction: an adapter that can answer
-- "who is in this workspace" as `{ id, name, email }` is a directory source, and
-- nothing here or there learns a product's name.

-- Everybody this organization knows about, whether or not they use Nod.
--
-- Separate from `org_directory()` rather than a widening of it: that function
-- feeds the chat's "who can I invite" prompt and is consumed by builds already
-- in the field, and handing it a row with no `user_id` would break their roster
-- outright. Two readers, two questions — "who are my colleagues on Nod" and "who
-- can this work be assigned to" — and they stopped having the same answer the
-- moment a person could exist without an account.
create function public.org_people()
    returns table (
        person_id    uuid,
        display_name text,
        email        text,
        has_account  boolean,
        -- Which connected products this person can actually be addressed in.
        -- The review card needs it to say "assignable" rather than offering
        -- somebody Nod would then fail to find.
        providers    text[]
    )
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

    select p.active_org_id into v_org from public.profiles p where p.user_id = v_caller;
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
               pe.display_name,
               pe.primary_email,
               pe.user_id is not null,
               coalesce(
                   (select array_agg(distinct pi.provider order by pi.provider)
                      from public.person_identities pi
                     where pi.person_id = pe.id and pi.provider <> 'email'),
                   '{}'::text[]
               )
          from public.people pe
         where pe.org_id = v_org
           and pe.deleted_at is null
         order by pe.display_name, pe.primary_email;
end;
$$;

revoke all on function public.org_people() from public, anon;
grant execute on function public.org_people() to authenticated;

-- ── Where an imported person came from ──────────────────────────────────────
--
-- A row created because somebody appeared in a connected workspace is a
-- different fact from a row created because they joined Nod, and an organization
-- clearing up has to be able to tell them apart. It is also what makes the
-- import idempotent in the honest direction: re-running it may update a name it
-- supplied, and must never overwrite one a person set for themselves.
alter table public.people
    add column source text not null default 'membership'
        check (source in ('membership', 'provider_directory'));

comment on column public.people.source is
    'membership: created because they joined the organization. provider_directory: created because they appeared in a connected workspace, and may have no Nod account.';

-- ── Importing ───────────────────────────────────────────────────────────────

-- Writes one workspace member into the organization, creating the person if
-- this is the first time we have seen the address.
--
-- One function rather than an upsert at each call site, because three rules have
-- to hold together and each of them is a way to corrupt a directory:
--
--   * match on the address and nothing else — two colleagues share a first name
--     far more often than an email;
--   * never take a name away from somebody who set one — a workspace's
--     "D. Barabash" must not replace "Dima" from their own profile;
--   * never attach an account. Somebody signing in is the only thing that may
--     set `user_id`, and it happens through the membership trigger.
create function public.import_workspace_member(
    p_org      uuid,
    p_provider text,
    p_external text,
    p_email    text,
    p_name     text
)
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_email  text := lower(nullif(btrim(coalesce(p_email, '')), ''));
    v_name   text := nullif(btrim(coalesce(p_name, '')), '');
    v_person uuid;
begin
    if v_email is null or position('@' in v_email) < 2 then
        return null;
    end if;

    select id into v_person
      from public.people
     where org_id = p_org and lower(primary_email) = v_email and deleted_at is null;

    if v_person is null then
        insert into public.people (org_id, primary_email, display_name, source)
        values (p_org, v_email, v_name, 'provider_directory')
        returning id into v_person;
    elsif v_name is not null then
        -- Only fills a gap. A name that came from a person's own profile is
        -- theirs, and a workspace's rendering of it is not an improvement.
        update public.people
           set display_name = coalesce(display_name, v_name), updated_at = now()
         where id = v_person and display_name is null;
    end if;

    insert into public.person_identities (person_id, provider, external_id, handle, source, verified_at)
    values (v_person, p_provider, p_external, coalesce(v_name, v_email), 'email_match', now())
    on conflict (org_id, provider, external_id) do update
       set person_id = excluded.person_id,
           handle    = excluded.handle,
           verified_at = now();

    return v_person;
end;
$$;

revoke all on function public.import_workspace_member(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.import_workspace_member(uuid, text, text, text, text) to service_role;
