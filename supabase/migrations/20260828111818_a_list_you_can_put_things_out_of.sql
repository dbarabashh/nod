-- A list you can take something out of without deleting it.
--
-- A folder shared with your team puts your colleagues' sessions in your library.
-- That is the point of it. What was missing is the other half: no way to say
-- "not this one". The only control the list offered was Delete, which for
-- somebody else's session did nothing at all — `20260828110347` made that
-- refusal audible, and the honest refusal made the gap obvious rather than
-- creating it.
--
-- So: a per-person hide. Not a delete, not an unshare, not a permission. The
-- session stays exactly where it is, its owner never learns of this, and every
-- other member of the folder still sees it. Only your list changes.
--
-- Deliberately impossible on your own session. The insert policy requires
-- `m.user_id <> auth.uid()`, because a session of yours that vanished from your
-- library without going to Trash is a session you cannot get back from any
-- screen that exists — Trash is the mechanism for your own, and two ways to make
-- your own work disappear, one of them without a thirty-day grace period, is a
-- support ticket waiting to be written.
--
-- No `unhide` RPC and no soft delete of the hide itself: the row *is* the state,
-- so removing it is the whole of undoing it. The clients filter on it and offer
-- the hidden set behind a filter, which is where unhiding lives.
--
-- The poke goes to `user:<self>` only, because that is the entire audience of
-- this fact. It is the first sender in this schema whose audience is one person
-- rather than a team — hiding is not an access change, and nobody else's view of
-- anything moved.
--
-- Deploy order and rollback. Purely additive: a released client that never
-- selects from this table behaves exactly as before, and an empty table is
-- byte-identical to not having it. Roll back by dropping the table, the function
-- and the trigger; nothing else references them.

create table public.meeting_hides (
    user_id    uuid        not null references auth.users(id)     on delete cascade,
    meeting_id uuid        not null references public.meetings(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, meeting_id)
);

-- The primary key already serves "what has this person hidden". This one serves
-- the cascade when a session is finally purged.
create index meeting_hides_meeting_idx on public.meeting_hides (meeting_id);

alter table public.meeting_hides enable row level security;

create policy "read own hides"
    on public.meeting_hides for select to authenticated
    using ((select auth.uid()) = user_id);

-- Somebody else's session, and only somebody else's. The `exists` runs under the
-- caller's own policies, so it also refuses a session they cannot see at all —
-- hiding one would otherwise be a way to test whether an id exists.
create policy "hide a session somebody shared with you"
    on public.meeting_hides for insert to authenticated
    with check (
        (select auth.uid()) = user_id
        and exists (
            select 1 from public.meetings m
             where m.id = meeting_id
               and m.user_id <> (select auth.uid())
        )
    );

create policy "unhide your own hides"
    on public.meeting_hides for delete to authenticated
    using ((select auth.uid()) = user_id);

grant select, insert, delete on table public.meeting_hides to authenticated;

-- Your other devices, and nobody else. Guarded and gated the same way the
-- session triggers are: outside any handler so an account erasure cascading
-- through a person's hides costs no subtransaction per row.
create function public._broadcast_hide_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user uuid := coalesce(new.user_id, old.user_id);
begin
    if not exists (select 1 from auth.users u where u.id = v_user) then
        return null;
    end if;
    begin
        perform public._notify_access_changed('user:' || v_user::text);
    exception when others then
        raise warning 'broadcast_hide_change failed: %', sqlerrm;
    end;
    return null;
end;
$$;

revoke all on function public._broadcast_hide_change() from public, anon, authenticated, service_role;

create trigger broadcast_access after insert or delete on public.meeting_hides
    for each row execute function public._broadcast_hide_change();
