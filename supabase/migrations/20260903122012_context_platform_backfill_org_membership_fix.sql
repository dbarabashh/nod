-- Fixes a real bug found running `backfill_meetings_into_source_objects()`
-- for the first time: copying `meetings.org_id`/`screen_observations.org_id`
-- straight into a new `source_objects` row abandons whole runs on the first
-- meeting whose org_id is still set but whose membership has since lapsed
-- (left the org, or membership no longer `active`) — `_stamp_org_id_from_context`
-- re-validates membership on every INSERT, unlike the original row, which
-- only had to pass that check once, back when it was first stamped.
--
-- The fix mirrors what the trigger itself checks, so a stale org_id degrades
-- to personal (`null`) instead of aborting the whole backfill.

create or replace function public.backfill_meetings_into_source_objects()
    returns integer
    language plpgsql
    set search_path = ''
as $$
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
    on conflict (object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

create or replace function public.backfill_ambient_into_source_objects()
    returns integer
    language plpgsql
    set search_path = ''
as $$
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
    on conflict (object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;
