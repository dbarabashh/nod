-- The one read the client needs: given the upcoming occurrence's ical_uid
-- (what `RemoteCalendar.swift` populates `CalendarOccurrence.externalID`
-- with), the ready "last time" briefing for it, or null. Deliberately NOT
-- `security definer` -- it runs as the calling `authenticated` user, so the
-- existing owner-read RLS policies on `calendar_events`/`source_objects`/
-- `context_nodes`/`briefings` are what actually authorize this, the same way
-- every other client-facing read in this schema works. A caller can never
-- see another user's briefing through this, because they could never see
-- the rows it joins through in the first place.
create function public.get_upcoming_meeting_briefing(p_ical_uid text)
    returns table (headline text, summary text, confidence numeric)
    language sql
    stable
    set search_path = ''
as $$
    select b.headline, b.summary, b.confidence
    from public.calendar_events ce
    join public.source_objects so
        on so.object_type = ce.provider || '/event'
        and so.external_id = coalesce(ce.external_event_id, ce.id::text)
        and so.connection_id is null
    join public.context_nodes cn on cn.source_object_id = so.id
    join public.briefings b
        on b.target_node_id = cn.id
        and b.briefing_type = 'upcoming_meeting'
        and b.status = 'ready'
    where ce.ical_uid = p_ical_uid
    limit 1;
$$;

revoke all on function public.get_upcoming_meeting_briefing(text) from public, anon;
grant execute on function public.get_upcoming_meeting_briefing(text) to authenticated;
