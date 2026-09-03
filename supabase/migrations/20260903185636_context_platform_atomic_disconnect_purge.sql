-- Every externally-owned source object must carry the connection that
-- produced it, or _purge_provider_data() can never find it to delete.
create or replace function public._resolve_active_connection_id(p_user_id uuid, p_provider text)
returns uuid
language sql
stable
set search_path to ''
as $function$
    select case when count(*) = 1 then (array_agg(id))[1] end
    from public.integration_connections
    where user_id = p_user_id and provider = p_provider and revoked_at is null
$function$;

-- Hard-delete of a connection must remove its source objects by itself:
-- the FK's own SET NULL action runs before the purge_provider_data trigger
-- (internal RI triggers sort ahead of it alphabetically), so the trigger's
-- `delete ... where connection_id = v_connection` was always matching zero rows.
alter table public.source_objects
    drop constraint source_objects_connection_id_fkey,
    add constraint source_objects_connection_id_fkey
        foreign key (connection_id) references public.integration_connections(id)
        on delete cascade;

-- Repair: attach existing calendar source objects to their one active connection.
update public.source_objects so
set connection_id = public._resolve_active_connection_id(so.user_id, so.provider)
where so.object_type = 'google-calendar/event'
  and so.connection_id is null
  and public._resolve_active_connection_id(so.user_id, so.provider) is not null;

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
            jsonb_build_object('ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is not null
        on conflict (connection_id, object_type, external_id) do nothing
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
            jsonb_build_object('ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is null
        on conflict (user_id, object_type, external_id) where connection_id is null do nothing
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
            jsonb_build_object('ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is not null
        on conflict (connection_id, object_type, external_id) do nothing
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
            jsonb_build_object('ical_uid', ical_uid, 'calendar_id', calendar_id,
                'organizer_email', organizer_email, 'attendees', attendees),
            starts_at, created_at, updated_at,
            md5(coalesce(title, '') || '|' || coalesce(starts_at::text, '')),
            '{}'::jsonb
        from resolved
        where resolved_connection_id is null
        on conflict (user_id, object_type, external_id) where connection_id is null do nothing
        returning 1
    )
    select count(*) into v_count from (
        select 1 from linked union all select 1 from unlinked
    ) counted;

    return v_count;
end;
$function$;
