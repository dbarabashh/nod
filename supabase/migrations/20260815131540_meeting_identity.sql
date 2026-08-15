-- Giving a meeting an identity two people can arrive at independently.
--
-- Until now a meeting is identified by its row, which is to say by who recorded
-- it. That was right while every account was one person: two recordings of one
-- call belonged to two strangers and there was nothing to say about the pair.
-- Inside an organization they are colleagues, the pair is the normal case, and
-- the product has no way to notice.
--
-- Two keys, because they fail in different places and neither covers the other:
--
--   `ical_uid`  — RFC 5545, the same string in every copy of one invitation, so
--                 it matches across people by construction. Present only when
--                 both of them have the meeting on a calendar we can read.
--   `room_key`  — the conferencing room, normalized from the join link. Weaker,
--                 because a recurring standup reuses one room forever, so it
--                 only means anything paired with a time. But it survives having
--                 no calendar at all, which is every user today.
--
-- Both are hints. Neither merges anything on its own: `merged_into` is written
-- by a person answering a question, never by a match.
--
-- Everything here is scoped to an organization, and that is a boundary rather
-- than a filter. Two strangers in one public Zoom room must never learn of each
-- other through this, so `org_id` is checked before a key is ever compared.

-- ── The room, as a key ──────────────────────────────────────────────────────

-- Normalizes a join link to the room it names, or null when it names none.
--
-- Deliberately narrow: only the products `ConferencingHost` already knows, and
-- only their unambiguous forms. A link that does not match returns null, which
-- means "no opinion" everywhere downstream. Guessing a key from an unrecognised
-- URL would invent matches between meetings that share nothing but a hostname.
create function public.conference_room_key(p_url text)
    returns text
    language sql
    immutable
    set search_path = ''
as $$
    select case
        -- Meet room codes are a fixed shape, which is what makes them safe to
        -- pull out of a URL that may carry anything after them.
        when u ~ 'meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})'
            then 'meet:' || (regexp_match(u, 'meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})'))[1]
        -- The numeric id, not the vanity host: one account's `acme.zoom.us` and
        -- `us02web.zoom.us` are the same room to everybody in it.
        when u ~ 'zoom\.us/(?:j|w|s)/(\d+)'
            then 'zoom:' || (regexp_match(u, 'zoom\.us/(?:j|w|s)/(\d+)'))[1]
        -- Teams carries the thread id percent-encoded in the path. Decoded here
        -- so two links that escaped it differently still land on one key.
        when u ~ 'teams\.(?:microsoft|live)\.com/.*(19(?:%3a|:)meeting_[a-z0-9_.-]+(?:%40|@)thread\.[a-z0-9]+)'
            then 'teams:' || replace(
                     replace(
                         (regexp_match(u, '(19(?:%3a|:)meeting_[a-z0-9_.-]+(?:%40|@)thread\.[a-z0-9]+)'))[1],
                         '%3a', ':'),
                     '%40', '@')
        when u ~ 'webex\.com/(?:meet|join)/([a-z0-9._-]+)'
            then 'webex:' || (regexp_match(u, 'webex\.com/(?:meet|join)/([a-z0-9._-]+)'))[1]
        when u ~ 'whereby\.com/([a-z0-9._-]+)'
            then 'whereby:' || (regexp_match(u, 'whereby\.com/([a-z0-9._-]+)'))[1]
        else null
    end
    from (select lower(coalesce(p_url, '')) as u) as normalized;
$$;

grant execute on function public.conference_room_key(text) to authenticated;

-- Stored rather than derived on read, so the calendar sweep pays for it once
-- instead of every matching query re-parsing every URL it looks at.
alter table public.calendar_events
    add column room_key text generated always as (public.conference_room_key(conference_url)) stored;

create index calendar_events_room_key_idx
    on public.calendar_events (user_id, room_key, starts_at) where room_key is not null;

-- ── The meeting's own copy ──────────────────────────────────────────────────

alter table public.meetings
    add column ical_uid text,
    add column room_key text,
    -- Where this recording was folded, once somebody said the two were one
    -- meeting. `set null` rather than cascade: deleting the surviving meeting
    -- must un-merge this one, never delete it. A recording is somebody's work
    -- and cannot be removed as a side effect of tidying up another row.
    add column merged_into uuid references public.meetings(id) on delete set null,
    add constraint meetings_merged_into_is_another
        check (merged_into is null or merged_into <> id);

-- The matching read, and the shape it is asked in: inside one organization,
-- around one time. `org_id` leads because it is the boundary — an index that
-- let a key be probed before it would invite exactly the query this must not
-- serve.
create index meetings_org_ical_uid_idx
    on public.meetings (org_id, ical_uid, started_at)
    where org_id is not null and ical_uid is not null and deleted_at is null;

create index meetings_org_room_key_idx
    on public.meetings (org_id, room_key, started_at)
    where org_id is not null and room_key is not null and deleted_at is null;

-- ── Who else recorded this ──────────────────────────────────────────────────

-- The colleagues' recordings of the meeting this one is. Empty for everybody
-- outside an organization, which is most people, and empty when nothing about
-- the meeting is identifiable.
--
-- `security definer` because it deliberately reads rows the caller cannot
-- select: the whole point is to learn that a colleague recorded this, and their
-- meeting is not shared with the caller. It answers with a title, a name and a
-- time — never with a transcript, a summary, or anything the sharing rules
-- would have had to grant.
create function public.same_meeting_in_org(p_meeting uuid)
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
    v_mine public.meetings;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select * into v_mine from public.meetings
     where id = p_meeting and user_id = auth.uid() and deleted_at is null;
    if v_mine.id is null then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;
    -- Outside an organization there is nobody this could be about, and no key
    -- should be compared at all.
    if v_mine.org_id is null then
        return;
    end if;
    if v_mine.ical_uid is null and v_mine.room_key is null then
        return;
    end if;

    return query
    select m.id,
           -- The same name the member list shows, through the same expression,
           -- so one person is not "Alina" in one pane and "alina" in the next.
           coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           m.title,
           m.started_at,
           case when v_mine.ical_uid is not null and m.ical_uid = v_mine.ical_uid
                then 'invitation' else 'room' end
      from public.meetings m
      join auth.users u on u.id = m.user_id
      left join public.profiles p on p.user_id = m.user_id
     where m.org_id = v_mine.org_id
       and m.user_id <> auth.uid()
       and m.deleted_at is null
       and m.merged_into is null
       and (
            (v_mine.ical_uid is not null and m.ical_uid = v_mine.ical_uid)
            or (v_mine.room_key is not null and m.room_key = v_mine.room_key)
       )
       -- A room is reused forever, so the time is what makes it a match rather
       -- than a coincidence of the same weekly standup a month apart. Applied to
       -- the invitation match too: two occurrences of a recurring series share
       -- one `iCalUID`, and only the start date tells them apart.
       and m.started_at between v_mine.started_at - interval '2 hours'
                            and v_mine.started_at + interval '2 hours'
     order by m.started_at;
end;
$$;

revoke all on function public.same_meeting_in_org(uuid) from public, anon;
grant execute on function public.same_meeting_in_org(uuid) to authenticated;

-- Folds this recording into a colleague's, once somebody has said they are one
-- meeting. Only ever the caller's own recording that moves: the target is left
-- untouched, so this can never reach into somebody else's row.
create function public.merge_meeting(p_source uuid, p_target uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_ok boolean;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_source = p_target then
        raise exception 'a meeting cannot be merged into itself' using errcode = '22023';
    end if;

    -- The target has to be one the matcher would have offered. Without this the
    -- function would let any meeting id be written into anybody's row, and the
    -- org boundary the matcher enforces would be decoration.
    select exists (
        select 1 from public.same_meeting_in_org(p_source) c where c.meeting_id = p_target
    ) into v_ok;
    if not v_ok then
        raise exception 'those are not the same meeting' using errcode = '42501';
    end if;

    update public.meetings
       set merged_into = p_target
     where id = p_source and user_id = auth.uid();
end;
$$;

revoke all on function public.merge_meeting(uuid, uuid) from public, anon;
grant execute on function public.merge_meeting(uuid, uuid) to authenticated;
