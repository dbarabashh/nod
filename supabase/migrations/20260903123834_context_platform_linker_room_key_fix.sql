-- Fixes a real bug found running the linker for the first time:
-- `calendar_events.room_key` does not exist — `trim_calendar_schema.sql`
-- (20260815143012, applied right after the column was added) removed the
-- stored generated column from `calendar_events` while `meetings.room_key`
-- stayed. `public.conference_room_key(url)` (the function that used to back
-- the generated column) is still live, so tier 2 now derives the key from
-- `calendar_events.conference_url` on the fly instead of reading a column
-- that isn't there.
create or replace function public.link_prior_meeting_for_calendar_source_object(p_calendar_source_object_id uuid)
    returns uuid
    language plpgsql
    set search_path = ''
as $$
declare
    v_cal_so           public.source_objects;
    v_ce               public.calendar_events;
    v_room_key         text;
    v_cal_node_id      uuid;
    v_meeting_node_id  uuid;
    v_meeting          record;
    v_edge_id          uuid;
    v_relation         text;
    v_confidence       numeric;
    v_resolver         text;
    v_attendee_tokens  text[];
begin
    select * into v_cal_so from public.source_objects where id = p_calendar_source_object_id;
    if v_cal_so.id is null or v_cal_so.object_type not like '%/event' then
        return null;
    end if;

    select * into v_ce from public.calendar_events
    where user_id = v_cal_so.user_id
      and (external_event_id = v_cal_so.external_id or id::text = v_cal_so.external_id)
    order by created_at desc
    limit 1;

    v_room_key := public.conference_room_key(v_ce.conference_url);

    insert into public.context_nodes (user_id, node_type, source_object_id, title, occurred_at)
    values (v_cal_so.user_id, 'calendar_event', v_cal_so.id, v_cal_so.title, v_cal_so.occurred_at)
    on conflict (source_object_id) do update set title = excluded.title, occurred_at = excluded.occurred_at, updated_at = now()
    returning id into v_cal_node_id;

    -- Tier 1: exact ical_uid.
    if v_ce.ical_uid is not null then
        select m.* into v_meeting from public.meetings m
        where m.user_id = v_cal_so.user_id and m.ical_uid = v_ce.ical_uid
          and m.deleted_at is null and m.merged_into is null
          and m.started_at < v_cal_so.occurred_at
        order by m.started_at desc limit 1;
        if v_meeting.id is not null then
            v_relation := 'same_event'; v_confidence := 1.0; v_resolver := 'ical_uid';
        end if;
    end if;

    -- Tier 2: exact conference room key, derived from the calendar event's
    -- own join link (calendar_events no longer stores this as a column).
    if v_meeting.id is null and v_room_key is not null then
        select m.* into v_meeting from public.meetings m
        where m.user_id = v_cal_so.user_id and m.room_key = v_room_key
          and m.deleted_at is null and m.merged_into is null
          and m.started_at < v_cal_so.occurred_at
        order by m.started_at desc limit 1;
        if v_meeting.id is not null then
            v_relation := 'same_event'; v_confidence := 0.95; v_resolver := 'room_key';
        end if;
    end if;

    -- Tier 3: attendee-token overlap, candidate confidence, >= 2 shared
    -- tokens required.
    if v_meeting.id is null and v_ce.attendees is not null then
        select array_agg(distinct lower(split_part(a ->> 'email', '@', 1)))
          into v_attendee_tokens
          from jsonb_array_elements(v_ce.attendees) a
          where length(split_part(a ->> 'email', '@', 1)) >= 3;

        if v_attendee_tokens is not null and array_length(v_attendee_tokens, 1) > 0 then
            select m.* into v_meeting from public.meetings m
            where m.user_id = v_cal_so.user_id
              and m.deleted_at is null and m.merged_into is null
              and m.started_at < v_cal_so.occurred_at
              and (
                  select count(*) from jsonb_each_text(coalesce(m.speaker_names, '{}'::jsonb)) sn
                  where lower(split_part(sn.value, ' ', 1)) = any (v_attendee_tokens)
              ) >= 2
            order by m.started_at desc
            limit 1;
            if v_meeting.id is not null then
                v_relation := 'discussed'; v_confidence := 0.75; v_resolver := 'attendee_overlap_v1';
            end if;
        end if;
    end if;

    if v_meeting.id is null then
        return null;
    end if;

    select cn.id into v_meeting_node_id
    from public.context_nodes cn
    join public.source_objects so on so.id = cn.source_object_id
    where so.object_type = 'nod/meeting' and so.external_id = v_meeting.id::text and so.connection_id is null;

    if v_meeting_node_id is null then
        insert into public.context_nodes (user_id, node_type, source_object_id, title, occurred_at)
        select so.user_id, 'meeting', so.id, so.title, so.occurred_at
        from public.source_objects so
        where so.object_type = 'nod/meeting' and so.external_id = v_meeting.id::text and so.connection_id is null
        on conflict (source_object_id) do update set updated_at = now()
        returning id into v_meeting_node_id;
    end if;

    if v_meeting_node_id is null then
        return null;
    end if;

    insert into public.context_edges (user_id, from_node_id, to_node_id, relation, confidence, resolver, valid_from)
    values (v_cal_so.user_id, v_cal_node_id, v_meeting_node_id, v_relation, v_confidence, v_resolver, now())
    on conflict (from_node_id, to_node_id, relation, resolver) where valid_to is null
        do update set confidence = excluded.confidence
    returning id into v_edge_id;

    return v_edge_id;
end;
$$;
