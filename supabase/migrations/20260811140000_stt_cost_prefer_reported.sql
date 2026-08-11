-- STT cost: prefer what the provider actually charged.
--
-- `usage_events.cost_usd` for transcribe rows used to be duration × rate card.
-- OpenRouter returns `usage.cost` on every STT response, so the proxy now
-- records that figure and falls back to the card only for providers that report
-- nothing (Groq, OpenAI). The measured rate is $0.09/audio-hour against the
-- $0.111 the card guessed — a 23% overstatement on ~40% of production traffic.
--
-- This function has to follow, or the monthly reconciliation would recompute
-- from the card and diverge from the rows it is meant to reconcile — the exact
-- failure its original comment claimed was impossible by construction.

update public.app_config
set stt_rates = jsonb_set(stt_rates, '{openrouter,default}', '0.09'::jsonb)
where stt_rates -> 'openrouter' ? 'default';

update public.app_config
set stt_rates = jsonb_set(stt_rates, '{openrouter,models,openai/whisper-large-v3}', '0.09'::jsonb)
where stt_rates -> 'openrouter' -> 'models' ? 'openai/whisper-large-v3';

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
    -- `where singleton` here has been raising since `mobile_platform_support`
    -- (2026-08-06) dropped that column, so this snapshot has not run since.
    -- The table is keyed by platform now and provider pricing is identical
    -- across rows, so the desktop row is the card.
    -- A missing card is no longer fatal either: rows carrying a reported cost
    -- still reconcile, and only the estimated ones drop out.
    select coalesce(stt_rates, '{}'::jsonb) into cfg
    from public.app_config where platform = 'macos';
    cfg := coalesce(cfg, '{}'::jsonb);

    insert into public.stt_cost_reconciliation
        (period_month, provider, est_requests, est_billed_hours, est_cost_usd)
    select
        p_month,
        s.prov,
        count(*),
        round(sum(s.billed_seconds) / 3600.0, 3),
        round(sum(s.cost), 4)
    from (
        select
            p.prov,
            greatest(e.audio_seconds, coalesce((cfg -> p.prov ->> 'min_billed_seconds')::numeric, 0)) as billed_seconds,
            coalesce(
                e.cost_usd,
                greatest(e.audio_seconds, coalesce((cfg -> p.prov ->> 'min_billed_seconds')::numeric, 0))
                    / 3600.0
                    * coalesce(
                        (cfg -> p.prov -> 'models' ->> p.model_id)::numeric,
                        (cfg -> p.prov ->> 'default')::numeric
                    )
            ) as cost
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
          and e.audio_seconds > 0
          and e.created_at >= p_month
          and e.created_at <  (p_month + interval '1 month')
    ) s
    where s.cost is not null
    group by s.prov
    on conflict (period_month, provider) do update
        set est_requests     = excluded.est_requests,
            est_billed_hours = excluded.est_billed_hours,
            est_cost_usd     = excluded.est_cost_usd;
end;
$$;

revoke all on function public.snapshot_stt_cost(date) from public, anon, authenticated;

comment on function public.snapshot_stt_cost(date) is
    'Monthly per-provider STT cost snapshot. Uses the cost recorded on each usage_events row (the provider''s own figure where it reports one) and falls back to app_config.stt_rates only for rows without one.';
