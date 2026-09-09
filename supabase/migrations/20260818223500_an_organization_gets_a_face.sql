-- An organization can carry its own mark instead of the first letter of its
-- name. The image is public by design: it is a logo, shown beside the name to
-- everyone who can already see the name, and a signed URL for it would expire
-- in the middle of a sidebar.
--
-- Who may set it is not public. Owners and admins run the organization; a
-- member changing the company's face is the same class of act as renaming it.

alter table public.organizations
    add column if not exists logo_path text;

comment on column public.organizations.logo_path is
    'Object path inside the org-logos bucket, or null for the monogram.';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'org-logos',
    'org-logos',
    true,
    -- The client downscales to a square before it uploads, so anything near
    -- this ceiling is a client that stopped doing that.
    2097152,
    array['image/png', 'image/jpeg']
)
on conflict (id) do nothing;

-- ── Who may write into the bucket ───────────────────────────────────────────
--
-- The first path segment is the organization's id, which is what ties an object
-- to the membership that authorizes it: `<org uuid>/logo.png`. The id is
-- checked against a uuid shape first — a cast on a malformed name would raise
-- rather than deny, and a policy has to answer no, not error.

create policy "org logos are world readable"
    on storage.objects for select
    using (bucket_id = 'org-logos');

create policy "org admins add their own logo"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'org-logos'
        and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_org_admin(((storage.foldername(name))[1])::uuid)
    );

create policy "org admins replace their own logo"
    on storage.objects for update to authenticated
    using (
        bucket_id = 'org-logos'
        and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_org_admin(((storage.foldername(name))[1])::uuid)
    )
    with check (
        bucket_id = 'org-logos'
        and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_org_admin(((storage.foldername(name))[1])::uuid)
    );

create policy "org admins remove their own logo"
    on storage.objects for delete to authenticated
    using (
        bucket_id = 'org-logos'
        and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_org_admin(((storage.foldername(name))[1])::uuid)
    );

-- ── Pointing the organization at it ─────────────────────────────────────────
--
-- The upload and the row are two writes, and the row is the one that decides
-- what is drawn — so it goes through a function that asks the same question the
-- storage policy asks, rather than through a table grant that would have to be
-- narrowed to one column.

create or replace function public.set_org_logo(p_org uuid, p_path text)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if not public.is_org_admin(p_org) then
        raise exception 'only an owner or admin can change the logo' using errcode = '42501';
    end if;

    update public.organizations
       set logo_path = nullif(btrim(coalesce(p_path, '')), '')
     where id = p_org and deleted_at is null;
end;
$$;

revoke all on function public.set_org_logo(uuid, text) from public, anon;
grant execute on function public.set_org_logo(uuid, text) to authenticated;
