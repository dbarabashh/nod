-- Phase 2 of the context-platform plan: the universal storage and job control
-- plane. Nothing reads or writes any of this yet — `INGESTION_V2` (see
-- `_shared/context-platform/flags.ts`) stays off until Phase 4 wires a real
-- connector to it. Shipping the schema ahead of its first writer is what lets
-- `supabase db push`/RLS/advisor review happen on its own, instead of bundled
-- into the first provider's PR.
--
-- `org_id` follows the exact stamping convention `stamp_org_id_on_content.sql`
-- established: database-assigned, never accepted from the client, immutable
-- once set. `integration_connections` keeps `team_id` for its own purpose
-- (which tool stack a team chose) — that is a different axis from `org_id`
-- (whose contract covers this content) and this migration does not conflate
-- them.

-- ── integration_connections: health and capability surface ─────────────────
--
-- Everything here already exists in spirit (`revoked_at` implies a state);
-- this makes it explicit enough for a readiness API to read without
-- reverse-engineering a timestamp.

alter table public.integration_connections
    add column capabilities   text[]      not null default '{}',
    add column state          text        not null default 'active'
        check (state in ('active', 'reauthorize', 'revoked', 'error')),
    add column last_healthy_at timestamptz,
    add column last_error_code text;

-- ── source_sync_states ──────────────────────────────────────────────────────
--
-- One row per (connection, scope) — a Gmail connection's inbox and a
-- Calendar's primary calendar are different cursors on the same connection.
-- Backend bookkeeping only: no owner-facing row here says anything a person
-- would read directly, so it carries no read policy at all (RLS enabled,
-- deny-all, same idiom as the rest of this schema's service-role-only tables).

create table public.source_sync_states (
    connection_id     uuid        not null references public.integration_connections(id) on delete cascade,
    source_scope      text        not null,
    cursor            jsonb,
    watermark         timestamptz,
    last_started_at   timestamptz,
    last_succeeded_at timestamptz,
    last_error_code   text,
    last_error_at     timestamptz,
    primary key (connection_id, source_scope)
);

alter table public.source_sync_states enable row level security;
grant select, insert, update, delete on table public.source_sync_states to service_role;

-- ── ingestion_jobs ───────────────────────────────────────────────────────────

create table public.ingestion_jobs (
    id                uuid        primary key default gen_random_uuid(),
    user_id           uuid        not null references auth.users(id) on delete cascade,
    connection_id     uuid        references public.integration_connections(id) on delete set null,
    provider          text        not null,
    job_kind          text        not null
        check (job_kind in ('historical_backfill', 'incremental_sync', 'reconcile', 'delete_source')),
    status            text        not null default 'queued'
        check (status in ('queued', 'running', 'retry_wait', 'completed', 'partial', 'failed', 'cancelled')),
    cursor            jsonb,
    requested_range   tstzrange,
    items_discovered  integer     not null default 0,
    items_processed   integer     not null default 0,
    items_failed      integer     not null default 0,
    attempt           integer     not null default 0,
    available_at      timestamptz not null default now(),
    claimed_at        timestamptz,
    heartbeat_at      timestamptz,
    finished_at       timestamptz,
    error_code        text,
    error_detail      text,
    idempotency_key   text        not null unique,
    created_at        timestamptz not null default now()
);

-- The queue scan: "what can a worker claim right now". Partial on the two
-- runnable states so a table mostly full of `completed` rows never grows this
-- index.
create index ingestion_jobs_runnable_idx
    on public.ingestion_jobs (available_at)
    where status in ('queued', 'retry_wait');
create index ingestion_jobs_user_created_idx
    on public.ingestion_jobs (user_id, created_at desc);
create index ingestion_jobs_connection_status_idx
    on public.ingestion_jobs (connection_id, status);

alter table public.ingestion_jobs enable row level security;

-- Owners read their own jobs — the readiness/progress UI (Phase 9) reads this
-- directly rather than through a bespoke summary endpoint. Nobody writes
-- through the client: a job is claimed, heartbeat, and completed only through
-- the SECURITY DEFINER RPCs below, callable only by `service_role`.
create policy "owners read own ingestion jobs"
    on public.ingestion_jobs
    for select
    to authenticated
    using (auth.uid() = user_id);

grant select, insert on table public.ingestion_jobs to service_role;

-- ── source_objects / source_object_versions / source_chunks ────────────────

create table public.source_objects (
    id                  uuid        primary key default gen_random_uuid(),
    user_id             uuid        not null references auth.users(id) on delete cascade,
    org_id              uuid        references public.organizations(id),
    connection_id       uuid        references public.integration_connections(id) on delete set null,
    provider            text        not null,
    object_type         text        not null,
    external_id         text        not null,
    parent_external_id  text,
    canonical_url       text,
    title               text,
    body                text,
    metadata            jsonb       not null default '{}',
    author_person_id    uuid        references public.people(id) on delete set null,
    occurred_at         timestamptz,
    source_created_at   timestamptz,
    source_updated_at   timestamptz,
    ingested_at         timestamptz not null default now(),
    content_hash        text        not null,
    visibility          jsonb       not null default '{}',
    deleted_at          timestamptz,
    unique (connection_id, object_type, external_id)
);

create index source_objects_user_idx on public.source_objects (user_id);
create index source_objects_org_idx  on public.source_objects (org_id) where org_id is not null;

alter table public.source_objects enable row level security;

create policy "owners read own source objects"
    on public.source_objects
    for select
    to authenticated
    using (auth.uid() = user_id);

grant select, insert, update, delete on table public.source_objects to service_role;

create trigger stamp_org_id before insert or update of org_id on public.source_objects
    for each row execute function public._stamp_org_id_from_context();

create table public.source_object_versions (
    id               uuid        primary key default gen_random_uuid(),
    source_object_id uuid        not null references public.source_objects(id) on delete cascade,
    org_id           uuid        references public.organizations(id),
    version_key      text        not null,
    content_hash     text        not null,
    title            text,
    body             text,
    metadata         jsonb       not null default '{}',
    observed_at      timestamptz not null,
    unique (source_object_id, version_key)
);

create index source_object_versions_object_idx on public.source_object_versions (source_object_id);

alter table public.source_object_versions enable row level security;

create policy "owners read own source object versions"
    on public.source_object_versions
    for select
    to authenticated
    using (
        exists (
            select 1 from public.source_objects so
            where so.id = source_object_id and so.user_id = auth.uid()
        )
    );

grant select, insert on table public.source_object_versions to service_role;

create trigger stamp_org_id before insert or update of org_id on public.source_object_versions
    for each row execute function public._stamp_org_id_from_parent('source_objects', 'source_object_id');

create table public.source_chunks (
    id               uuid        primary key default gen_random_uuid(),
    source_object_id uuid        not null references public.source_objects(id) on delete cascade,
    org_id           uuid        references public.organizations(id),
    chunk_index      integer     not null,
    content          text        not null,
    embedding        vector(384),
    locator          jsonb       not null default '{}',
    token_count      integer,
    created_at       timestamptz not null default now(),
    unique (source_object_id, chunk_index)
);

create index source_chunks_vec_idx on public.source_chunks using hnsw (embedding vector_cosine_ops);
create index source_chunks_fts_idx on public.source_chunks using gin (to_tsvector('english', content));

alter table public.source_chunks enable row level security;

create policy "owners read own source chunks"
    on public.source_chunks
    for select
    to authenticated
    using (
        exists (
            select 1 from public.source_objects so
            where so.id = source_object_id and so.user_id = auth.uid()
        )
    );

grant select, insert, delete on table public.source_chunks to service_role;

create trigger stamp_org_id before insert or update of org_id on public.source_chunks
    for each row execute function public._stamp_org_id_from_parent('source_objects', 'source_object_id');

-- ── Atomic job control ───────────────────────────────────────────────────────
--
-- Worker-only RPCs: the caller is `service_role`, which already bypasses RLS
-- and is Nod's own backend, not a person — so these do not re-check
-- `auth.uid()` the way a user-facing SECURITY DEFINER function must. The
-- authorization boundary here is the grant itself (`service_role` only,
-- revoked from everyone else), matching how `nango-webhook`-triggered writes
-- are trusted elsewhere in this schema.

-- Exponential backoff, capped at 30 minutes: attempt 0 → 1m, 1 → 2m, 2 → 4m …
create function public._ingestion_backoff(p_attempt integer)
    returns interval
    language sql
    immutable
    set search_path = ''
as $$
    select least(
        (power(2, greatest(p_attempt, 0)) * interval '1 minute'),
        interval '30 minutes'
    );
$$;

revoke all on function public._ingestion_backoff(integer) from public, anon, authenticated;

-- A job stuck retrying this many times is a dead letter, not a backlog entry:
-- `complete_ingestion_job` reports failure past this bound instead of
-- rescheduling it into the same loop forever.
create function public._ingestion_max_attempts()
    returns integer
    language sql
    immutable
    set search_path = ''
as $$
    select 5;
$$;

revoke all on function public._ingestion_max_attempts() from public, anon, authenticated;

-- Claims exactly one runnable job for `p_provider` (any `job_kind`), or none.
-- `for update skip locked` is what makes two workers polling at once land on
-- different rows instead of both claiming the same one.
create function public.claim_ingestion_job(p_provider text)
    returns public.ingestion_jobs
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_job public.ingestion_jobs;
begin
    select * into v_job
    from public.ingestion_jobs
    where provider = p_provider
      and status in ('queued', 'retry_wait')
      and available_at <= now()
    order by available_at
    limit 1
    for update skip locked;

    if v_job.id is null then
        return null;
    end if;

    update public.ingestion_jobs
    set status = 'running',
        attempt = attempt + 1,
        claimed_at = now(),
        heartbeat_at = now()
    where id = v_job.id
    returning * into v_job;

    return v_job;
end;
$$;

revoke all on function public.claim_ingestion_job(text) from public, anon, authenticated;
grant execute on function public.claim_ingestion_job(text) to service_role;

-- Progress + liveness. Counts are set, not incremented — the worker knows its
-- own running totals and a crashed-and-resumed worker must not double-count
-- what an earlier attempt already reported.
create function public.heartbeat_ingestion_job(
    p_job_id uuid,
    p_items_discovered integer default null,
    p_items_processed integer default null,
    p_items_failed integer default null
)
    returns void
    language sql
    security definer
    set search_path = ''
as $$
    update public.ingestion_jobs
    set heartbeat_at = now(),
        items_discovered = coalesce(p_items_discovered, items_discovered),
        items_processed = coalesce(p_items_processed, items_processed),
        items_failed = coalesce(p_items_failed, items_failed)
    where id = p_job_id and status = 'running';
$$;

revoke all on function public.heartbeat_ingestion_job(uuid, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.heartbeat_ingestion_job(uuid, integer, integer, integer) to service_role;

-- Ends a claimed job. `p_retry: true` reschedules through the backoff curve
-- unless `_ingestion_max_attempts` is already spent, in which case the job is
-- marked `failed` (dead-lettered) instead of rescheduled again.
create function public.complete_ingestion_job(
    p_job_id uuid,
    p_status text,
    p_retry boolean default false,
    p_error_code text default null,
    p_error_detail text default null
)
    returns public.ingestion_jobs
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_job public.ingestion_jobs;
begin
    if p_status not in ('completed', 'partial', 'failed', 'cancelled') then
        raise exception 'complete_ingestion_job: invalid terminal status %', p_status using errcode = '22023';
    end if;

    select * into v_job from public.ingestion_jobs where id = p_job_id;
    if v_job.id is null then
        return null;
    end if;

    if p_retry and p_status = 'failed' and v_job.attempt < public._ingestion_max_attempts() then
        update public.ingestion_jobs
        set status = 'retry_wait',
            available_at = now() + public._ingestion_backoff(v_job.attempt),
            error_code = p_error_code,
            error_detail = p_error_detail
        where id = p_job_id
        returning * into v_job;
        return v_job;
    end if;

    update public.ingestion_jobs
    set status = p_status,
        finished_at = now(),
        error_code = p_error_code,
        error_detail = p_error_detail
    where id = p_job_id
    returning * into v_job;

    return v_job;
end;
$$;

revoke all on function public.complete_ingestion_job(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.complete_ingestion_job(uuid, text, boolean, text, text) to service_role;
