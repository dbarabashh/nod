-- STT cost tracking: rate card in config + monthly reconciliation.
--
-- Transcription providers (Groq, OpenAI, OpenRouter) don't return a per-request
-- cost the way OpenRouter's chat endpoint does, so `usage_events.cost_usd` was
-- always NULL for `transcribe`. The llm-proxy now estimates it from
-- audio duration x a per-provider rate; this migration moves that rate card OUT
-- of code into `app_config.stt_rates` so a provider price change is a one-row
-- UPDATE, not a redeploy — and gives the monthly reconciliation job the same
-- source of truth.
--
-- Why a rate card at all (and not the invoice): STT APIs return no cost, so the
-- only ground truth is the provider invoice. The estimate is a proxy; the
-- reconciliation table below is where we compare it to the real invoice each
-- month and catch drift (a price change, a billing-floor change, a routing
-- change) — because hardcoded rates never notice on their own.

-- 1. Rate card in config -----------------------------------------------------
-- Shape: { "<provider>": { "default": <usd/h>, "min_billed_seconds": <int>,
--                          "models": { "<model id>": <usd/h> } } }
-- `min_billed_seconds` captures provider billing floors — Groq bills a 10s
-- minimum per request (our VAD segments average ~5s, so raw duration would
-- understate cost ~2x). `models` overrides the per-provider default for a
-- specific model id; OpenAI always serves whisper-1 so its default covers every
-- requested id. Verified against Groq's public pricing 2026-06: large-v3
-- $0.111/h, large-v3-turbo $0.04/h; OpenAI whisper-1 $0.006/min = $0.36/h.
alter table public.app_config
    add column stt_rates jsonb not null default jsonb_build_object(
        'groq', jsonb_build_object(
            'default', 0.111,
            'min_billed_seconds', 10,
            'models', jsonb_build_object(
                'openai/whisper-large-v3-turbo', 0.04,
                'openai/whisper-large-v3', 0.111
            )
        ),
        'openai', jsonb_build_object(
            'default', 0.36,
            'min_billed_seconds', 0
        ),
        'openrouter', jsonb_build_object(
            'default', 0.111,
            'min_billed_seconds', 0,
            'models', jsonb_build_object(
                'openai/whisper-large-v3-turbo', 0.04,
                'openai/whisper-large-v3', 0.111
            )
        )
    );

-- 2. Reconciliation ledger ---------------------------------------------------
-- One row per (month, provider): our estimate vs the actual provider invoice.
-- `actual_invoice_usd` is filled in by hand from the Groq/OpenAI console each
-- month; `variance_pct` then shows how far the estimate drifted — a large gap
-- means a rate/floor/routing change we need to fold back into `stt_rates`.
-- Internal financial data: RLS on, no authenticated policy (service role only;
-- surface via founder-dashboard RPCs if needed).
create table public.stt_cost_reconciliation (
    period_month       date          not null,
    provider           text          not null,
    est_requests       bigint        not null,
    est_billed_hours   numeric(12, 3) not null,
    est_cost_usd       numeric(12, 4) not null,
    actual_invoice_usd numeric(12, 4),
    note               text,
    variance_pct       numeric generated always as (
        case
            when actual_invoice_usd is not null and est_cost_usd > 0
            then round((actual_invoice_usd - est_cost_usd) / est_cost_usd * 100, 1)
        end
    ) stored,
    created_at         timestamptz   not null default now(),
    primary key (period_month, provider)
);

alter table public.stt_cost_reconciliation enable row level security;

-- 3. Snapshot function -------------------------------------------------------
-- Aggregates a month's `transcribe` usage into per-provider estimated cost,
-- using the SAME rate card the proxy uses (app_config.stt_rates) so estimate
-- and reconciliation can't diverge by construction. Idempotent per month.
-- Defaults to the previous calendar month (UTC).
create or replace function public.snapshot_stt_cost(
    p_month date default (date_trunc('month', now() at time zone 'utc') - interval '1 month')::date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    cfg jsonb;
begin
    select stt_rates into cfg from public.app_config where singleton;
    if cfg is null then
        raise notice 'snapshot_stt_cost: app_config.stt_rates is null — nothing recorded for %', p_month;
        return;
    end if;

    insert into public.stt_cost_reconciliation
        (period_month, provider, est_requests, est_billed_hours, est_cost_usd)
    select
        p_month,
        s.prov,
        count(*),
        round(sum(s.billed_seconds) / 3600.0, 3),
        round(sum(s.billed_seconds / 3600.0 * s.rate), 4)
    from (
        select
            p.prov,
            greatest(e.audio_seconds, coalesce((cfg -> p.prov ->> 'min_billed_seconds')::numeric, 0)) as billed_seconds,
            coalesce(
                (cfg -> p.prov -> 'models' ->> p.model_id)::numeric,
                (cfg -> p.prov ->> 'default')::numeric
            ) as rate
        from public.usage_events e
        cross join lateral (
            select
                -- Rows recorded before provider tagging carry no "provider:"
                -- prefix; those were Groq (our default STT) — price them as such.
                case when e.model like '%:%' then split_part(e.model, ':', 1) else 'groq' end as prov,
                case when e.model like '%:%' then substring(e.model from position(':' in e.model) + 1) else e.model end as model_id
        ) p
        where e.kind = 'transcribe'
          and e.status between 200 and 299
          and e.audio_seconds > 0  -- match the proxy, which records null cost for non-positive duration
          and e.created_at >= p_month
          and e.created_at <  (p_month + interval '1 month')
    ) s
    where s.rate is not null
    group by s.prov
    on conflict (period_month, provider) do update
        set est_requests     = excluded.est_requests,
            est_billed_hours = excluded.est_billed_hours,
            est_cost_usd     = excluded.est_cost_usd;
end;
$$;

-- Internal cost job, not a client RPC. Strip the default PUBLIC execute grant so
-- it isn't callable via PostgREST (the public schema is exposed) — only the cron
-- scheduler (superuser) and service role invoke it. Mirrors the founder RPCs.
revoke all on function public.snapshot_stt_cost(date) from public, anon, authenticated;

-- 4. Monthly cron ------------------------------------------------------------
-- 04:00 UTC on the 2nd of each month — snapshots the prior month once the
-- provider's billing period has closed. Wrapped like the purge job so a
-- project without pg_cron doesn't block the migration; run manually if skipped.
do $$
begin
    create extension if not exists pg_cron;
exception when others then
    raise notice 'pg_cron unavailable (%) — stt cost snapshot schedule skipped. Enable via dashboard, then cron.schedule(...) manually.', sqlerrm;
end $$;

do $$
begin
    perform cron.schedule(
        'snapshot-stt-cost',
        '0 4 2 * *',
        $cmd$select public.snapshot_stt_cost();$cmd$
    );
exception when others then
    raise notice 'cron.schedule unavailable (%) — stt cost snapshot will not run automatically.', sqlerrm;
end $$;
