-- The matcher looked for the boundary in the wrong column.
--
-- `same_meeting_in_org` scoped on `meetings.org_id`, and that column is null for
-- almost every meeting on purpose: `_stamp_org_id_from_context` only fills it
-- when the organization has switched `allow_personal_context` **off**, which is
-- not the default and should not be. Personal is the default destination and
-- membership alone shares nothing — that rule is right and stays.
--
-- The consequence was that the two facts never met. Two colleagues recording one
-- call each produced two personal meetings carrying the same `ical_uid` and the
-- same `room_key`, in one organization, and the function returned before
-- comparing either key. Merging has therefore been unreachable for every
-- organization running the default policy, which is all of them.
--
-- The boundary that was actually wanted is the one the header of
-- `20260815131540` describes: "Two strangers in one public Zoom room must never
-- learn of each other." That is a statement about the two *people*, not about
-- who owns the content. So the scope is now shared active membership: both
-- owners in one organization, checked before any key is compared. A personal
-- meeting stays personal — this offers a question, and `merge_meeting` still
-- requires a person to answer it.

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
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select mine.ical_uid, mine.room_key, mine.started_at
      into v_ical, v_room, v_started
      from public.meetings mine
     where mine.id = p_meeting and mine.user_id = auth.uid() and mine.deleted_at is null;
    if not found then
        raise exception 'that meeting is not yours' using errcode = '42501';
    end if;
    -- Nothing identifies this recording, so nothing can be compared to it.
    if v_ical is null and v_room is null then
        return;
    end if;

    -- The caller's own organization, and only while their membership is live.
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
           -- The same name the member list shows, through the same expression,
           -- so one person is not "Alina" in one pane and "alina" in the next.
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
       -- A room is reused forever, so the time is what makes it a match rather
       -- than a coincidence of the same weekly standup a month apart. Applied to
       -- the invitation match too: two occurrences of a recurring series share
       -- one `iCalUID`, and only the start date tells them apart.
       and m.started_at between v_started - interval '2 hours'
                            and v_started + interval '2 hours'
     order by m.started_at;
end;
$$;
