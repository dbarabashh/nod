-- A meeting's identity stops being something the client can rewrite.
--
-- `same_meeting_in_org` answers "who else in this organization recorded this
-- call" by reading `ical_uid`, `room_key` and `started_at` off the caller's own
-- meeting row and comparing them to everybody else's. Those three columns were
-- writable: the update policy is `using ((select auth.uid()) = user_id)` with no
-- column list, so a member could set them to whatever they liked and be answered
-- about a call they were never in.
--
-- `conference_room_key` normalizes a personal Zoom room, a Webex `/meet/` link
-- and a recurring Meet code into one stable string, so a single invitation ever
-- received from somebody — or a join link in an email signature — was enough to
-- name the room. Stepping `started_at` in four-hour jumps then walked out the
-- titles, owners and times of every recording anyone in the organization had
-- ever made there. `merge_meeting` was never reachable this way — it checks
-- `can_read_meeting_via_grant` for a target you do not own — so what leaked is
-- metadata, but it is the metadata the matcher exists to keep between the two
-- people who were actually in the room.
--
-- Two changes, matching where each value legitimately comes from:
--
--   * `room_key` is derived, never sent. No client encodes it — `Meeting`'s
--     `CodingKeys` carry `ical_uid` and not this — so any value arriving in one
--     is forged by construction, and it is dropped.
--   * `ical_uid` is sent by the client, because the macOS Calendars path reads
--     it from EventKit and never reaches the server any other way. So the lease
--     wins when the lease knows: `_stamp_lease_identity` derives it server-side
--     from `calendar_events`, and a value the server read itself always beats a
--     value a client claims. Only a meeting with no identified lease keeps what
--     it was told, which is the EventKit-only case this cannot take away without
--     removing the feature for most people.
--
-- After insert all three are settled, so the update trigger restores them rather
-- than raising: the client upserts the whole row mid-recording and would
-- otherwise have to learn which of its own columns it is no longer allowed to
-- resend.

create or replace function public._inherit_lease_identity()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_ical text;
    v_room text;
begin
    select l.ical_uid, l.room_key into v_ical, v_room
      from public.meeting_start_leases l
     where l.meeting_id = new.id and l.user_id = new.user_id;

    if v_ical is not null or v_room is not null then
        new.ical_uid := v_ical;
        new.room_key := v_room;
    else
        new.room_key := null;
    end if;

    return new;
end;
$$;

create function public._pin_meeting_identity()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    new.ical_uid   := old.ical_uid;
    new.room_key   := old.room_key;
    new.started_at := old.started_at;
    return new;
end;
$$;

revoke all on function public._pin_meeting_identity() from public, anon, authenticated;

-- Only for a client writing the table directly. A `SECURITY DEFINER` function
-- runs as this trigger's owner, so `merge_meeting` and every other server-side
-- path is exempt by construction — and so is a future forward migration that has
-- to repair these columns, which an unconditional trigger would swallow without
-- raising, leaving the repair silently undone.
create trigger pin_meeting_identity
    before update on public.meetings
    for each row
    when (current_user in ('authenticated', 'anon'))
    execute function public._pin_meeting_identity();

-- Keys claimed while the columns were writable. `same_meeting_in_org` answers
-- from them, so leaving them is leaving the leak in the data after closing it in
-- the code. The lease is the server's own record of what the recording was, so
-- anything the meeting says that the lease does not is dropped rather than
-- corrected — a meeting with no lease keeps nothing it could only have claimed.
update public.meetings m
   set ical_uid = l.ical_uid,
       room_key = l.room_key
  from public.meeting_start_leases l
 where l.meeting_id = m.id
   and l.user_id = m.user_id
   and (m.ical_uid is distinct from l.ical_uid or m.room_key is distinct from l.room_key);

-- A meeting with no lease keeps its `ical_uid` — that is the EventKit case the
-- insert rule above deliberately still trusts — but not its `room_key`, which no
-- client sends and which nothing but a hand-written request could have put there.
update public.meetings m
   set room_key = null
 where m.room_key is not null
   and not exists (
       select 1 from public.meeting_start_leases l
        where l.meeting_id = m.id and l.user_id = m.user_id
   );
