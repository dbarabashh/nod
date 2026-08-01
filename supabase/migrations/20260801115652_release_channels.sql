-- Who sees a build before everyone else.
--
-- Sparkle filters appcast items tagged `<sparkle:channel>` against the set the
-- client returns from `allowedChannelsForUpdater:`; an untagged item goes to
-- everyone. So a beta lives in the same `appcast.xml` the whole install base
-- polls, and membership is what decides who can see it — which means it has to
-- reach the client BEFORE its update check, not with the feed.
--
-- Writes are service-role only. A column on `profiles` would have been the
-- smaller change, but users can UPDATE their own profile row, and self-enrolling
-- into an unreleased build is exactly what must not be possible.

create table public.release_channel_members (
    user_id  uuid        primary key references auth.users(id) on delete cascade,
    channel  text        not null,
    added_at timestamptz not null default now()
);

alter table public.release_channel_members enable row level security;

create policy "users read own release channel"
    on public.release_channel_members
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

-- Enrolment takes emails because that is what the release script is handed.
-- Every input address comes back with whether it resolved, so a typo fails the
-- release loudly instead of shipping a beta to nobody.
create or replace function public.set_release_channel(p_emails text[], p_channel text)
returns table (input_email text, matched_user uuid, enrolled boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.release_channel_members (user_id, channel)
    select u.id, p_channel
      from unnest(p_emails) as e
      join auth.users u on lower(u.email) = lower(trim(e))
    on conflict (user_id) do update
       set channel = excluded.channel, added_at = now();

    return query
    select lower(trim(e)), u.id, (u.id is not null)
      from unnest(p_emails) as e
      left join auth.users u on lower(u.email) = lower(trim(e));
end;
$$;

create or replace function public.clear_release_channel(p_emails text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_removed integer;
begin
    delete from public.release_channel_members m
     using auth.users u
     where m.user_id = u.id
       and lower(u.email) in (select lower(trim(e)) from unnest(p_emails) as e);
    get diagnostics v_removed = row_count;
    return v_removed;
end;
$$;

revoke all on function public.set_release_channel(text[], text)    from public, anon, authenticated;
revoke all on function public.clear_release_channel(text[])        from public, anon, authenticated;
grant execute on function public.set_release_channel(text[], text) to service_role;
grant execute on function public.clear_release_channel(text[])     to service_role;
