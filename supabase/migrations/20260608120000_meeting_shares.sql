-- Meeting sharing — privacy-by-default public links.
--
-- A share is an EXPLICIT, revocable grant: a row in `meeting_shares` holds an
-- opaque random `token`. Nothing is shared until the owner creates one, and
-- deleting/revoking the row kills access immediately. This is the deliberate
-- contrast with "anyone with the link" defaults — the link is summary-only and
-- never auto-created.
--
-- Anonymous viewers never touch `meetings` directly (RLS forbids it). They go
-- through `get_shared_meeting(token)`, which returns the recap/summary fields
-- ONLY — never the transcript. The transcript is reachable solely server-side
-- (service role, in the `share-ask` edge function) for the interactive Q&A.

create table public.meeting_shares (
    token       uuid        primary key default gen_random_uuid(),
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    created_by  uuid        not null references auth.users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    revoked_at  timestamptz
);

-- One row per (meeting, owner) active share — `create_meeting_share` reuses an
-- existing live share instead of minting a new token each click. The partial
-- unique index enforces "at most one un-revoked share per meeting".
create unique index meeting_shares_active_idx
    on public.meeting_shares (meeting_id)
    where revoked_at is null;

create index meeting_shares_owner_idx
    on public.meeting_shares (created_by);

alter table public.meeting_shares enable row level security;

-- Owners fully manage their own shares. Anonymous viewers get NOTHING here —
-- they read through the security-definer function below, never the table.
create policy "owners read own shares"
    on public.meeting_shares
    for select
    to authenticated
    using (auth.uid() = created_by);

create policy "owners create own shares"
    on public.meeting_shares
    for insert
    to authenticated
    with check (
        auth.uid() = created_by
        and exists (
            select 1 from public.meetings m
            where m.id = meeting_id
              and m.user_id = auth.uid()
              and m.deleted_at is null
        )
    );

create policy "owners update own shares"
    on public.meeting_shares
    for update
    to authenticated
    using (auth.uid() = created_by);

create policy "owners delete own shares"
    on public.meeting_shares
    for delete
    to authenticated
    using (auth.uid() = created_by);

-- Create (or reuse) a share for a meeting the caller owns; returns the token.
-- SECURITY DEFINER so it can read `meetings` ownership and upsert atomically,
-- but the ownership check inside makes it safe to expose to any authenticated
-- user. Idempotent: a meeting with a live share returns that same token.
create or replace function public.create_meeting_share(p_meeting_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_token uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;

    if not exists (
        select 1 from public.meetings m
        where m.id = p_meeting_id
          and m.user_id = auth.uid()
          and m.deleted_at is null
    ) then
        raise exception 'meeting not found or not owned by caller';
    end if;

    select token into v_token
    from public.meeting_shares
    where meeting_id = p_meeting_id
      and revoked_at is null
    limit 1;

    if v_token is null then
        insert into public.meeting_shares (meeting_id, created_by)
        values (p_meeting_id, auth.uid())
        returning token into v_token;
    end if;

    return v_token;
end;
$$;

-- Public, summary-only read for a share token. Granted to `anon` so the web
-- viewer reads it with the publishable key and NO account. Deliberately omits
-- `transcript` — viewers see the recap, never the raw conversation. Revoked or
-- soft-deleted rows return zero rows (link is dead).
create or replace function public.get_shared_meeting(p_token uuid)
returns table (
    id          uuid,
    title       text,
    summary     text,
    recap_json  jsonb,
    kind        text,
    language    text,
    started_at  timestamptz,
    ended_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select m.id, m.title, m.summary, m.recap_json, m.kind, m.language,
           m.started_at, m.ended_at
    from public.meeting_shares s
    join public.meetings m on m.id = s.meeting_id
    where s.token = p_token
      and s.revoked_at is null
      and m.deleted_at is null;
$$;

-- Revoke a share (soft — keeps the audit row). Owner only.
create or replace function public.revoke_meeting_share(p_token uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.meeting_shares
    set revoked_at = now()
    where token = p_token
      and created_by = auth.uid()
      and revoked_at is null;
end;
$$;

revoke all on function public.create_meeting_share(uuid) from public;
revoke all on function public.get_shared_meeting(uuid)   from public;
revoke all on function public.revoke_meeting_share(uuid) from public;

grant execute on function public.create_meeting_share(uuid) to authenticated;
grant execute on function public.revoke_meeting_share(uuid) to authenticated;
-- anon = the web viewer's publishable key; authenticated can read too.
grant execute on function public.get_shared_meeting(uuid)   to anon, authenticated;
