-- Leaving a call and coming back should not cost you a second meeting.
--
-- A dropped connection, a laptop that slept, a "let me dial back in" — each ends
-- one recording and starts another. Both carry the same `ical_uid` and the same
-- `room_key`, minutes apart, and both belong to the same person. Today they are
-- filed as two: two rows in Sessions, two recaps written from half a
-- conversation each, and the hour billed twice.
--
-- `same_meeting_in_org` cannot answer this. It exists to find *somebody else's*
-- recording of a call you were both in, and excludes your own on purpose —
-- otherwise every colleague's list would fill with your own copies.
--
-- So a second matcher, for the other half of the question, and one place where
-- `merge_meeting` looks for a legal target. What stays unchanged is who decides:
-- a match is offered, never applied. Two recordings minutes apart in one room
-- are usually one meeting and sometimes genuinely two — a call that ended and a
-- different call that reused the room — and the person in the room knows which.

-- ── My own recording of the same room ───────────────────────────────────────

create or replace function public.my_earlier_recording(p_meeting uuid)
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
    v_ical    text;
    v_room    text;
    v_started timestamptz;
    v_ended   timestamptz;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select mine.ical_uid, mine.room_key, mine.started_at, mine.ended_at
      into v_ical, v_room, v_started, v_ended
      from public.meetings mine
     where mine.id = p_meeting and mine.user_id = auth.uid() and mine.deleted_at is null;
    if not found then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    return query
    select m.id,
           'You',
           m.title,
           m.started_at,
           case when v_ical is not null and m.ical_uid = v_ical
                then 'invitation' else 'room' end
      from public.meetings m
     where m.user_id = auth.uid()
       and m.id <> p_meeting
       and m.deleted_at is null
       and m.merged_into is null
       and (
            (v_ical is not null and m.ical_uid = v_ical)
            or (v_room is not null and m.room_key = v_room)
       )
       -- Adjacent, not merely same-day. A standup reuses one room every morning
       -- and one `iCalUID` for the whole series; what makes these one meeting is
       -- that the gap between them is a person rejoining, not a day passing.
       and m.started_at between v_started - interval '2 hours'
                            and v_started + interval '2 hours'
       and (
            m.ended_at between v_started - interval '30 minutes' and v_started
            or v_ended between m.started_at - interval '30 minutes' and m.started_at
       )
     order by m.started_at;
end;
$$;

revoke all on function public.my_earlier_recording(uuid) from public, anon;
grant execute on function public.my_earlier_recording(uuid) to authenticated;

-- ── One place that decides what may be merged ───────────────────────────────

create or replace function public.merge_meeting(p_source uuid, p_target uuid)
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

    -- The target has to be one a matcher would have offered. Without this the
    -- function would let any meeting id be written into anybody's row, and the
    -- boundaries the matchers enforce would be decoration. Both matchers count:
    -- a colleague's recording of the same call, or your own of the same room.
    select exists (
        select 1 from public.same_meeting_in_org(p_source) c where c.meeting_id = p_target
        union all
        select 1 from public.my_earlier_recording(p_source) c where c.meeting_id = p_target
    ) into v_ok;
    if not v_ok then
        raise exception 'those are not the same meeting' using errcode = '42501';
    end if;

    -- A merged recording is no longer its own meeting, so it must stop counting
    -- as one. Nothing is deleted: the transcript stays readable under the row it
    -- was captured in, and `merged_into` is what every list and every window
    -- query already filters on.
    update public.meetings
       set merged_into = p_target
     where id = p_source and user_id = auth.uid();
end;
$$;

revoke all on function public.merge_meeting(uuid, uuid) from public, anon;
grant execute on function public.merge_meeting(uuid, uuid) to authenticated;
