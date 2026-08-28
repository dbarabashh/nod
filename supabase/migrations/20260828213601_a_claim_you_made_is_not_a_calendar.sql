-- A meeting identity the device claimed stops being able to discover meetings.
--
-- The migration before this pinned `meetings.ical_uid` and `room_key` and let the
-- lease win over what a client sends. It said "`room_key` is derived, never
-- sent". That was wrong, and `set_lease_identity` is why: it is `SECURITY
-- DEFINER`, granted to `authenticated`, and writes `room_key =
-- coalesce(room_key, conference_room_key(p_conference_url))` onto the caller's
-- own lease. It exists for a good reason — the macOS Calendars path reads
-- EventKit on the device and reaches the server no other way — but it means the
-- key `_inherit_lease_identity` faithfully copies onto the meeting can still be
-- one the caller made up. Start a recording, claim a colleague's standing
-- conference room within the two-minute window, and `same_meeting_in_org`
-- answers about their meetings.
--
-- Removing the claim would remove the feature from most people, so the claim
-- stays and stops being worth forging. The lease now records where its identity
-- came from, and the matcher asks for more when the answer is "the device said
-- so": the two recordings must actually overlap, rather than merely fall within
-- two hours of each other. A forged key then buys nothing that recording at the
-- same time as somebody would not already show — which is the fact the feature
-- exists to surface — and it costs a real concurrent recording per probe.
--
-- A server-read calendar identity keeps the wider window, because there the
-- server knows what meeting it was.

alter table public.meeting_start_leases
    add column identity_source text
        check (identity_source in ('calendar', 'device'));

-- Existing rows were stamped from `calendar_events` or claimed by a device, and
-- nothing recorded which. Treated as a device claim: the narrower rule is the
-- safe answer for an identity whose origin is unknown.
update public.meeting_start_leases
   set identity_source = 'device'
 where ical_uid is not null or room_key is not null;

create or replace function public._stamp_lease_identity()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    select active_org_id into new.org_id
      from public.profiles where user_id = new.user_id;

    select i.ical_uid, i.room_key into new.ical_uid, new.room_key
      from public._calendar_identity_at(new.user_id, now()) i;

    if new.ical_uid is not null or new.room_key is not null then
        new.identity_source := 'calendar';
    end if;

    return new;
end;
$$;

create or replace function public.set_lease_identity(
    p_meeting uuid,
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room text := public.conference_room_key(p_conference_url);
    v_ical text := nullif(btrim(coalesce(p_ical_uid, '')), '');
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    update public.meeting_start_leases
       set ical_uid = coalesce(ical_uid, v_ical),
           room_key = coalesce(room_key, v_room),
           identity_source = coalesce(identity_source, 'device')
     where meeting_id = p_meeting
       and user_id = auth.uid()
       and status = 'active'
       and granted_at > now() - interval '2 minutes'
       and (ical_uid is null or room_key is null);
end;
$$;

-- ── The matcher asks how the caller knows ───────────────────────────────────

create or replace function public.same_meeting_in_org(p_meeting uuid)
    returns table (
        meeting_id uuid,
        owner_name text,
        title text,
        started_at timestamptz,
        matched_on text
    )
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
declare
    v_org     uuid;
    v_ical    text;
    v_room    text;
    v_started timestamptz;
    v_ended   timestamptz;
    v_claimed boolean;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select mine.ical_uid, mine.room_key, mine.started_at, coalesce(mine.ended_at, mine.started_at)
      into v_ical, v_room, v_started, v_ended
      from public.meetings mine
     where mine.id = p_meeting and mine.user_id = auth.uid() and mine.deleted_at is null;
    if not found then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    -- Anything the server did not read for itself, including a meeting with no
    -- lease at all.
    select coalesce(l.identity_source, 'device') <> 'calendar'
      into v_claimed
      from public.meeting_start_leases l
     where l.meeting_id = p_meeting and l.user_id = auth.uid();
    v_claimed := coalesce(v_claimed, true);

    select p.active_org_id into v_org
      from public.profiles p
     where p.user_id = auth.uid();
    if v_org is null then
        return;
    end if;
    if not exists (
        select 1 from public.org_members m
         where m.org_id = v_org and m.user_id = auth.uid() and m.status = 'active'
    ) then
        return;
    end if;

    return query
    select m.id,
           coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           m.title,
           m.started_at,
           case when v_ical is not null and m.ical_uid = v_ical
                then 'invitation' else 'room' end
      from public.meetings m
      join public.org_members om
        on om.user_id = m.user_id and om.org_id = v_org and om.status = 'active'
      join auth.users u on u.id = m.user_id
      left join public.profiles p on p.user_id = m.user_id
     where m.user_id <> auth.uid()
       and m.deleted_at is null
       and m.merged_into is null
       and (
            (v_ical is not null and m.ical_uid = v_ical)
            or (v_room is not null and m.room_key = v_room)
       )
       -- Always, whatever the identity is worth. `started_at` is pinned after
       -- insert but `ended_at` is not — the client legitimately moves it when a
       -- recording finishes — so an overlap test bounded only by `ended_at`
       -- could be widened indefinitely by claiming a recording that never
       -- ended.
       and m.started_at between v_started - interval '2 hours'
                            and v_started + interval '2 hours'
       and (
            -- Read from the caller's own synced calendar: the server knows what
            -- meeting it was, and two people recording one call rarely press
            -- record together, so the window above is the whole test.
            not v_claimed
            -- Claimed by a device, so worth nothing on its own: the two
            -- recordings also have to have been running at the same time.
            -- Being in a room is something you can only assert about a moment
            -- you were also recording.
            or (m.started_at <= v_ended and coalesce(m.ended_at, m.started_at) >= v_started)
       )
     order by m.started_at;
end;
$$;
