-- Native source_objects key was global (object_type, external_id), so a
-- shared Google Calendar event silently dropped every attendee but the
-- first to backfill. Scope it to the owning user.
drop index if exists public.source_objects_native_key_idx;

create unique index source_objects_native_key_idx
    on public.source_objects (user_id, object_type, external_id)
    where (connection_id is null);

create or replace function public.backfill_calendar_events_into_source_objects()
 returns integer
 language plpgsql
 set search_path to ''
as $function$
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
    on conflict (user_id, object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$function$;

create or replace function public.backfill_calendar_events_into_source_objects(p_user_id uuid default null::uuid)
 returns integer
 language plpgsql
 set search_path to ''
as $function$
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
    on conflict (user_id, object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$function$;

create or replace function public.backfill_ambient_into_source_objects()
 returns integer
 language plpgsql
 set search_path to ''
as $function$
declare
    v_count integer;
begin
    insert into public.source_objects (
        user_id, org_id, provider, object_type, external_id, canonical_url,
        title, body, occurred_at, source_created_at, content_hash, visibility
    )
    select
        so.user_id,
        case when so.org_id is not null and public._is_org_member_of(so.org_id, so.user_id)
            then so.org_id else null end,
        'ambient',
        'ambient/window_observation',
        so.id::text,
        so.source_url,
        so.source_title,
        so.content,
        so.observed_at,
        so.created_at,
        so.content_hash,
        '{}'::jsonb
    from public.screen_observations so
    on conflict (user_id, object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$function$;

create or replace function public.backfill_meetings_into_source_objects()
 returns integer
 language plpgsql
 set search_path to ''
as $function$
declare
    v_count integer;
begin
    insert into public.source_objects (
        user_id, org_id, provider, object_type, external_id,
        title, body, metadata, occurred_at, source_created_at,
        source_updated_at, content_hash, visibility
    )
    select
        m.user_id,
        case when m.org_id is not null and public._is_org_member_of(m.org_id, m.user_id)
            then m.org_id else null end,
        'nod',
        'nod/meeting',
        m.id::text,
        m.title,
        m.summary,
        jsonb_build_object('kind', m.kind, 'source_platform', m.source_platform, 'ical_uid', m.ical_uid),
        m.started_at,
        m.created_at,
        m.distilled_at,
        md5(coalesce(m.title, '') || '|' || coalesce(m.summary, '')),
        '{}'::jsonb
    from public.meetings m
    where m.deleted_at is null and m.merged_into is null
    on conflict (user_id, object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$function$;

-- Repair: insert the calendar rows the old global key silently dropped.
select public.backfill_calendar_events_into_source_objects(null::uuid);
