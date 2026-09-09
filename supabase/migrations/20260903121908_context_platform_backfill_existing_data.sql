-- Phase 3 of the context-platform plan: backfill existing Nod data into the
-- envelope built in Phase 2. `INGESTION_V2` is still off and nothing reads
-- `source_objects`/`source_chunks` yet, so this is purely additive — existing
-- search (`session_embeddings`, `hybrid_retrieval`) is untouched.
--
-- Callable RPCs rather than one-shot `insert ... select` statements in the
-- migration body, because "resumable" (the plan's own Phase 3 DoD) means
-- re-runnable — someone recovering from a partial run, or backfilling after
-- restoring a native object that was previously deleted, calls the function
-- again rather than needing a new migration. Every insert is `on conflict do
-- nothing` against a natural key, so a rerun costs a no-op scan, not a
-- duplicate.
--
-- `visibility` has no natural default (Phase 2 deliberately left it
-- `not null` with none, forcing every writer to be explicit) — every row
-- here gets `'{}'::jsonb`, meaning "no restriction beyond the owner", which
-- is what backfilled personal content already was.
--
-- `screen_observations` backfills as one set-based insert rather than
-- app-level batches: ~27k local rows is ordinary bulk-insert volume for
-- Postgres. "In batches" in the plan's own wording is about a live
-- provider's paginated API (Phase 4), not a single already-local table.

-- Natural-key uniqueness for objects that don't come through a broker
-- connection (every source here: `nod`, `google-calendar`, `ambient`).
-- `connection_id` is null for all of them, so the general
-- `(connection_id, object_type, external_id)` constraint does not apply —
-- Postgres treats NULLs as distinct, which the Phase 2 review flagged as
-- deliberate for orphaned *provider* objects but is the wrong behavior for
-- objects that were never connection-scoped in the first place and must
-- still dedupe on rerun.
create unique index source_objects_native_key_idx
    on public.source_objects (object_type, external_id)
    where connection_id is null;

create function public.backfill_meetings_into_source_objects()
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
        m.org_id,
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

revoke all on function public.backfill_meetings_into_source_objects() from public, anon, authenticated;
grant execute on function public.backfill_meetings_into_source_objects() to service_role;

create function public.backfill_calendar_events_into_source_objects()
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
    on conflict (object_type, external_id) where connection_id is null do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

revoke all on function public.backfill_calendar_events_into_source_objects() from public, anon, authenticated;
grant execute on function public.backfill_calendar_events_into_source_objects() to service_role;

create function public.backfill_ambient_into_source_objects()
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
        so.org_id,
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

revoke all on function public.backfill_ambient_into_source_objects() from public, anon, authenticated;
grant execute on function public.backfill_ambient_into_source_objects() to service_role;

-- Dual-writes existing meeting chunks into `source_chunks`, keyed off the
-- `source_objects` row the meetings backfill created — so this must run
-- after `backfill_meetings_into_source_objects`, and a meeting the caller
-- never backfilled (deleted/merged, filtered out above) correctly backfills
-- no chunks either, since the join finds no parent.
create function public.backfill_session_embeddings_into_source_chunks()
    returns integer
    language plpgsql
    set search_path = ''
as $$
declare
    v_count integer;
begin
    insert into public.source_chunks (
        source_object_id, org_id, chunk_index, content, embedding, locator, created_at
    )
    select
        so.id,
        se.org_id,
        se.chunk_idx,
        se.content,
        se.embedding,
        jsonb_build_object('meeting_id', se.meeting_id, 'kind', se.kind, 'started_at', se.started_at),
        se.created_at
    from public.session_embeddings se
    join public.source_objects so
        on so.object_type = 'nod/meeting'
        and so.external_id = se.meeting_id::text
        and so.connection_id is null
    on conflict (source_object_id, chunk_index) do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

revoke all on function public.backfill_session_embeddings_into_source_chunks() from public, anon, authenticated;
grant execute on function public.backfill_session_embeddings_into_source_chunks() to service_role;
