-- Fixes from an independent adversarial review of
-- `20260903120558_context_platform_ingestion_control_plane.sql`. Nothing here
-- edits an applied migration; every change is a forward `create or replace`,
-- `update`, or `comment on`.

-- ── Real bug: `complete_ingestion_job` could mutate a job that wasn't running.
--
-- Unlike `heartbeat_ingestion_job`, the original version matched solely on
-- `id = p_job_id` with no `status = 'running'` guard and an unlocked initial
-- read. Concrete failure: a worker's completion call is retried after a
-- network timeout even though the first call already landed — the retry
-- either flips an already-`completed` job back to `retry_wait` (re-enqueuing
-- finished work), or overwrites a job a second worker has since re-claimed
-- and is actively running, silently corrupting its `items_*` counters.
--
-- The initial read now locks the row (`for update`) and requires
-- `status = 'running'`; both terminal UPDATEs repeat that guard. A call that
-- doesn't match returns null instead of mutating nothing quietly — the same
-- "nothing to do" signal `claim_ingestion_job` already uses, so callers can
-- tell a stale/duplicate completion from a real one.
create or replace function public.complete_ingestion_job(
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

    select * into v_job
    from public.ingestion_jobs
    where id = p_job_id and status = 'running'
    for update;

    if v_job.id is null then
        return null;
    end if;

    if p_retry and p_status = 'failed' and v_job.attempt < public._ingestion_max_attempts() then
        update public.ingestion_jobs
        set status = 'retry_wait',
            available_at = now() + public._ingestion_backoff(v_job.attempt),
            error_code = p_error_code,
            error_detail = p_error_detail
        where id = p_job_id and status = 'running'
        returning * into v_job;
        return v_job;
    end if;

    update public.ingestion_jobs
    set status = p_status,
        finished_at = now(),
        error_code = p_error_code,
        error_detail = p_error_detail
    where id = p_job_id and status = 'running'
    returning * into v_job;

    return v_job;
end;
$$;

-- ── Real defect: `state` was never backfilled from the existing `revoked_at`.
--
-- Every row — including connections a user had already revoked before this
-- migration — landed on the blanket default `state = 'active'`. A readiness
-- API reading `state` would report a revoked connection as healthy.
update public.integration_connections
set state = 'revoked'
where revoked_at is not null and state = 'active';

-- ── Index shape: `claim_ingestion_job` filters on `provider` first, but the
-- partial index only covered `available_at` — a real deployment with several
-- providers would scan every runnable job across all of them in date order
-- and heap-filter out the wrong ones, instead of seeking straight to one
-- provider's rows.
drop index public.ingestion_jobs_runnable_idx;
create index ingestion_jobs_runnable_idx
    on public.ingestion_jobs (provider, available_at)
    where status in ('queued', 'retry_wait');

-- ── Documentation-only: the backoff comment claimed attempt 0 -> 1m, but
-- `claim_ingestion_job` increments `attempt` before the first failure is ever
-- recorded, so `complete_ingestion_job` always sees attempt >= 1 by the time
-- it calls this. Not a functional bug (the escalation curve is internally
-- consistent) — the prose just described the wrong number.
comment on function public._ingestion_backoff(integer) is
    'Backoff for the ATTEMPT NUMBER AFTER claim_ingestion_job''s increment: attempt 1 -> 2m, '
    '2 -> 4m, 3 -> 8m, 4 -> 16m, capped at 30m. Attempt 0 never reaches this function.';

-- ── Documentation-only: idempotency is the caller's responsibility, and
-- nothing enforces it structurally today.
comment on column public.ingestion_jobs.idempotency_key is
    'Caller-derived, e.g. "<provider>:<job_kind>:<connection_id>[:<range>]". Uniqueness alone '
    'does not make job creation idempotent -- a caller minting a fresh value per call defeats '
    'it. A future connector must derive this deterministically, never generate it randomly.';

-- ── Documentation-only: NULL connection_id (post `on delete set null`) is
-- deliberately excluded from this uniqueness check by ordinary Postgres NULL
-- semantics. An orphaned object (its connection was disconnected) is
-- historical, not something new imports still need to dedupe against.
comment on constraint source_objects_connection_id_object_type_external_id_key
    on public.source_objects is
    'connection_id is nullable; NULLs never conflict here by design -- an orphaned object '
    '(connection since deleted) is not deduplicated against.';
