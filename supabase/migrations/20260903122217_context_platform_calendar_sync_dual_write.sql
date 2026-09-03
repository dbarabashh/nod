-- Phase 4, first slice: keep `source_objects` current as Google Calendar
-- events change, not just backfilled once. `calendar-sync` (an existing,
-- already-scheduled function) will call this per sync with the syncing
-- user's id, so each run only rescans that user's own calendar rows instead
-- of the whole table — the one-time Phase 3 catch-up already covered
-- everyone, and re-running it globally on every sync would cost a full-table
-- scan per user per sync.
--
-- The added parameter defaults to null (= every user), so the existing
-- Phase 3 call site (`select backfill_calendar_events_into_source_objects()`)
-- keeps working unchanged.
create or replace function public.backfill_calendar_events_into_source_objects(p_user_id uuid default null)
    returns integer
    language plpgsql
    set search_path = ''
as $$
declare
    v_count integer;
begin
    insert into public.source_objects (
        user_id, provider, object_type, external_id, canonical_url,
        title, metadata, occurred_at, source_created_at, source_updated_at,
        content_hash, visibility
    )
    select
        ce.user_id,
        ce.provider,
        ce.provider || '/event',
        coalesce(ce.external_event_id, ce.id::text),
        ce.conference_url,
        ce.title,
        jsonb_build_object(
            'ical_uid', ce.ical_uid, 'calendar_id', ce.calendar_id,
            'organizer_email', ce.organizer_email, 'attendees', ce.attendees
        ),
        ce.starts_at,
        ce.created_at,
        ce.updated_at,
        md5(coalesce(ce.title, '') || '|' || coalesce(ce.starts_at::text, '')),
        '{}'::jsonb
    from public.calendar_events ce
    where p_user_id is null or ce.user_id = p_user_id
    on conflict (object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;
