-- Removing the parts of the calendar schema nothing can read.
--
-- A review of the two migrations above found several objects that were written
-- for readers that do not exist and, in two cases, cannot exist:
--
--   `is_cancelled`  — the sweep asks Google with `showDeleted=false`, so an event
--                     with `status = 'cancelled'` is never returned and the
--                     column can never be true. Cancellation already has an
--                     answer: the sweep deletes what the provider stops
--                     returning for a window it asked about.
--   `etag`          — stored on every row and read by nothing. An etag is for
--                     conditional fetching, and `20260815122516` explains at
--                     length why this sync deliberately has none.
--   `room_key`      — a generated column on `calendar_events`, recomputed on
--                     every upsert of every event on every pass, with no query
--                     anywhere that filters on it. The room key that matters is
--                     the one on `meetings`.
--   two indexes     — `calendar_events_ical_uid_idx` and
--                     `calendar_events_room_key_idx`. Both are fully
--                     materialised (their columns are populated for essentially
--                     every row) and neither serves a query: the only identity
--                     matching in the schema reads `public.meetings`, which has
--                     its own pair of partial indexes.
--
-- The equivalents on `meetings` stay. They are partial on `ical_uid is not null`
-- / `room_key is not null`, nothing writes those columns yet, so they are empty
-- and cost nothing until the producer lands.

alter table public.calendar_events
    drop column if exists is_cancelled,
    drop column if exists etag,
    drop column if exists room_key;

drop index if exists public.calendar_events_ical_uid_idx;

-- The nightly purge filters on `coalesce(ends_at, starts_at)` while every index
-- on this table leads with `user_id`, so it was reading the whole table.
create index if not exists calendar_events_ended_idx
    on public.calendar_events ((coalesce(ends_at, starts_at)));

-- `select *` into a `public.meetings` record detoasts the summary and the recap
-- on every call, and this reads neither.
create or replace function public.same_meeting_in_org(p_meeting uuid)
    returns table (
        meeting_id uuid,
        owner_name text,
        title text,
        started_at timestamptz,
        matched_on text
    )
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org     uuid;
    v_ical    text;
    v_room    text;
    v_started timestamptz;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select org_id, ical_uid, room_key, started_at
      into v_org, v_ical, v_room, v_started
      from public.meetings
     where id = p_meeting and user_id = auth.uid() and deleted_at is null;
    if not found then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;
    -- Outside an organization there is nobody this could be about, and no key
    -- should be compared at all.
    if v_org is null or (v_ical is null and v_room is null) then
        return;
    end if;

    return query
    select m.id,
           -- The same name the member list shows, through the same expression,
           -- so one person is not "Alina" in one pane and "alina" in the next.
           coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           m.title,
           m.started_at,
           case when v_ical is not null and m.ical_uid = v_ical
                then 'invitation' else 'room' end
      from public.meetings m
      join auth.users u on u.id = m.user_id
      left join public.profiles p on p.user_id = m.user_id
     where m.org_id = v_org
       and m.user_id <> auth.uid()
       and m.deleted_at is null
       and m.merged_into is null
       and (
            (v_ical is not null and m.ical_uid = v_ical)
            or (v_room is not null and m.room_key = v_room)
       )
       -- A room is reused forever, so the time is what makes it a match rather
       -- than a coincidence of the same weekly standup a month apart. Applied to
       -- the invitation match too: two occurrences of a recurring series share
       -- one `iCalUID`, and only the start date tells them apart.
       and m.started_at between v_started - interval '2 hours'
                            and v_started + interval '2 hours'
     order by m.started_at;
end;
$$;

-- The comment on this policy in `20260815122516` described a `sync_token` column
-- that the same migration deliberately does not create.
comment on policy "users read own calendar sync state" on public.calendar_sync_state is
    'Readable so the app can say when it last looked and why it stopped. Never writable: nothing a client could say about our conversation with the provider is worth trusting.';
