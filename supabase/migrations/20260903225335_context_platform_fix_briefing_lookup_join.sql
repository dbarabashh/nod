-- get_upcoming_meeting_briefing() still joined on `so.connection_id is null`,
-- which every calendar source object satisfied before the P0.2 repair. Now
-- that all of them carry a real connection_id, that predicate matches zero
-- rows, so a successfully generated briefing could never be returned. Match
-- by owner instead, and require the caller to be that owner (ce.ical_uid is
-- shared verbatim across every attendee's own calendar_events row, so without
-- this predicate a shared event's uid could return another user's briefing).
create or replace function public.get_upcoming_meeting_briefing(p_ical_uid text)
 returns table(headline text, summary text, confidence numeric, meeting_id uuid, meeting_title text, meeting_occurred_at timestamp with time zone)
 language sql
 stable
 set search_path to ''
as $function$
    select
        b.headline, b.summary, b.confidence,
        meeting_so.external_id::uuid, meeting_so.title, meeting_so.occurred_at
    from public.calendar_events ce
    join public.source_objects so
        on so.user_id = ce.user_id
        and so.object_type = ce.provider || '/event'
        and so.external_id = coalesce(ce.external_event_id, ce.id::text)
        and so.deleted_at is null
    join public.context_nodes cn on cn.source_object_id = so.id
    join public.briefings b
        on b.target_node_id = cn.id
        and b.briefing_type = 'upcoming_meeting'
        and b.status = 'ready'
    join public.briefing_items bi on bi.briefing_id = b.id
    join public.context_nodes meeting_cn on meeting_cn.id = bi.target_node_id
    join public.source_objects meeting_so
        on meeting_so.id = meeting_cn.source_object_id
        and meeting_so.user_id = ce.user_id
    where ce.ical_uid = p_ical_uid
      and ce.user_id = auth.uid()
    limit 1;
$function$;
