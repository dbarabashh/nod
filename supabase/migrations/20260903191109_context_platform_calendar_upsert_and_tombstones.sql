-- Insert-only dual-write left source_objects stale forever on reschedule/
-- rename, and never marked a provider-cancelled event gone. Make the backfill
-- idempotent (upsert, clearing any tombstone on reappearance) and add an
-- atomic prune routine that tombstones the matching source object in the
-- same statement that removes the calendar_events row.

create or replace function public.backfill_calendar_events_into_source_objects()
 returns integer
 language plpgsql
 set search_path to ''
as $function$
declare
    v_count integer;
begin
    with resolved as (
        select ce.*, public._resolve_active_connection_id(ce.user_id, ce.provider) as resolved_connection_id
        from public.calendar_events ce
    ),
    linked as (
        insert into public.source_objects (
            user_id, connection_id, provider, object_type, external_id, canonical_url,
            title, metadata, occurred_at, source_created_at, source_updated_at,
            content_hash, visibility
        )
        select
            user_id, resolved_connection_id, provider, provider || '/event',
            coalesce(external_event_id, id::text), conference_url, title,
            jsonb_build_object(
                'ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees
            ),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is not null
        on conflict (connection_id, object_type, external_id) do update set
            canonical_url = excluded.canonical_url,
            title = excluded.title,
            metadata = excluded.metadata,
            occurred_at = excluded.occurred_at,
            source_updated_at = excluded.source_updated_at,
            content_hash = excluded.content_hash,
            deleted_at = null
        returning 1
    ),
    unlinked as (
        insert into public.source_objects (
            user_id, provider, object_type, external_id, canonical_url,
            title, metadata, occurred_at, source_created_at, source_updated_at,
            content_hash, visibility
        )
        select
            user_id, provider, provider || '/event',
            coalesce(external_event_id, id::text), conference_url, title,
            jsonb_build_object(
                'ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees
            ),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is null
        on conflict (user_id, object_type, external_id) where connection_id is null do update set
            canonical_url = excluded.canonical_url,
            title = excluded.title,
            metadata = excluded.metadata,
            occurred_at = excluded.occurred_at,
            source_updated_at = excluded.source_updated_at,
            content_hash = excluded.content_hash,
            deleted_at = null
        returning 1
    )
    select count(*) into v_count from (
        select 1 from linked union all select 1 from unlinked
    ) counted;

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
    with resolved as (
        select ce.*, public._resolve_active_connection_id(ce.user_id, ce.provider) as resolved_connection_id
        from public.calendar_events ce
        where p_user_id is null or ce.user_id = p_user_id
    ),
    linked as (
        insert into public.source_objects (
            user_id, connection_id, provider, object_type, external_id, canonical_url,
            title, metadata, occurred_at, source_created_at, source_updated_at,
            content_hash, visibility
        )
        select
            user_id, resolved_connection_id, provider, provider || '/event',
            coalesce(external_event_id, id::text), conference_url, title,
            jsonb_build_object(
                'ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees
            ),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is not null
        on conflict (connection_id, object_type, external_id) do update set
            canonical_url = excluded.canonical_url,
            title = excluded.title,
            metadata = excluded.metadata,
            occurred_at = excluded.occurred_at,
            source_updated_at = excluded.source_updated_at,
            content_hash = excluded.content_hash,
            deleted_at = null
        returning 1
    ),
    unlinked as (
        insert into public.source_objects (
            user_id, provider, object_type, external_id, canonical_url,
            title, metadata, occurred_at, source_created_at, source_updated_at,
            content_hash, visibility
        )
        select
            user_id, provider, provider || '/event',
            coalesce(external_event_id, id::text), conference_url, title,
            jsonb_build_object(
                'ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees
            ),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is null
        on conflict (user_id, object_type, external_id) where connection_id is null do update set
            canonical_url = excluded.canonical_url,
            title = excluded.title,
            metadata = excluded.metadata,
            occurred_at = excluded.occurred_at,
            source_updated_at = excluded.source_updated_at,
            content_hash = excluded.content_hash,
            deleted_at = null
        returning 1
    )
    select count(*) into v_count from (
        select 1 from linked union all select 1 from unlinked
    ) counted;

    return v_count;
end;
$function$;

create or replace function public.prune_calendar_window(
    p_user_id uuid,
    p_provider text,
    p_calendar_id text,
    p_from timestamptz,
    p_to timestamptz,
    p_stamped_at timestamptz
)
returns integer
language plpgsql
set search_path to ''
as $function$
declare
    v_count integer;
begin
    with pruned as (
        delete from public.calendar_events
        where user_id = p_user_id
          and provider = p_provider
          and calendar_id = p_calendar_id
          and starts_at >= p_from
          and starts_at <= p_to
          and updated_at < p_stamped_at
        returning id, external_event_id
    ),
    tombstoned as (
        update public.source_objects so
        set deleted_at = now()
        from pruned p
        where so.user_id = p_user_id
          and so.object_type = p_provider || '/event'
          and so.external_id = coalesce(p.external_event_id, p.id::text)
          and so.deleted_at is null
        returning so.id
    )
    select count(*) into v_count from pruned;

    return v_count;
end;
$function$;

revoke all on function public.prune_calendar_window(uuid, text, text, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.prune_calendar_window(uuid, text, text, timestamptz, timestamptz, timestamptz) to service_role;
