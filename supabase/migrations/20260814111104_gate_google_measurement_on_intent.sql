-- Posting conversions to Google becomes a stated intent rather than a side
-- effect of which secrets happen to be set.
--
-- `invoke_google_measurement_sync` returns early unless `supabase_project_url`
-- and `analytics_sync_secret` are both present. That is a real guard, and it is
-- why the fifteen-minute job is inert outside production today. But it makes one
-- secret carry two meanings — "this function can run" and "these conversions are
-- real" — and the two come apart the moment someone sets `analytics_sync_secret`
-- on a branch to exercise the analytics pipeline. Nothing about that intent says
-- "start reporting conversions", yet that is what it would switch on.
--
-- `google_measurement_enabled` separates them. The transport secrets stay what
-- they are; this says whether the environment is the one whose conversions
-- count.
--
-- Seeded from the environment's own state rather than left for someone to
-- remember: an instance that already holds `analytics_sync_secret` is, by
-- definition, the one already reporting, so it keeps reporting. Every other
-- instance — the sandbox today, any preview branch later, since branches
-- inherit no secrets — starts inert and stays inert until somebody says
-- otherwise. Without this seed the same migration would silently stop
-- production's conversions, which is the failure that is harder to notice than
-- the one it prevents.
--
-- Migrations here read the vault and never write it. This writes a flag derived
-- from state already in the instance, not a credential, and only where none
-- exists — no secret material enters version control.

do $$
begin
    if exists (
        select 1 from vault.decrypted_secrets
        where name = 'analytics_sync_secret' and nullif(decrypted_secret, '') is not null
    ) and not exists (
        select 1 from vault.decrypted_secrets where name = 'google_measurement_enabled'
    ) then
        perform vault.create_secret(
            'true',
            'google_measurement_enabled',
            'Whether conversions from this instance are reported to Google for real.'
        );
    end if;
end;
$$;

create or replace function public.invoke_google_measurement_sync()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_project_url text;
    v_sync_secret text;
    v_enabled text;
    v_request_id bigint;
begin
    select decrypted_secret into v_enabled
      from vault.decrypted_secrets where name = 'google_measurement_enabled';

    if coalesce(v_enabled, '') <> 'true' then
        return null;
    end if;

    select decrypted_secret into v_project_url
      from vault.decrypted_secrets where name = 'supabase_project_url';
    select decrypted_secret into v_sync_secret
      from vault.decrypted_secrets where name = 'analytics_sync_secret';

    if coalesce(v_project_url, '') = '' or coalesce(v_sync_secret, '') = '' then
        return null;
    end if;

    select net.http_post(
        url := rtrim(v_project_url, '/') || '/functions/v1/sync-google-measurement',
        headers := jsonb_build_object(
            'x-sync-secret', v_sync_secret,
            'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    ) into v_request_id;

    return v_request_id;
end;
$$;

revoke all on function public.invoke_google_measurement_sync() from public, anon, authenticated;
grant execute on function public.invoke_google_measurement_sync() to service_role;

-- The readiness surface has to show the flag, or "the schedule is active and the
-- secrets are present" reads as "conversions are flowing" in the one environment
-- where it no longer follows.
create or replace function public.google_analytics_sync_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_project_url_present boolean := false;
    v_sync_secret_present boolean := false;
    v_measurement_enabled boolean := false;
    v_measurement_schedule boolean := false;
    v_ads_schedule boolean := false;
begin
    begin
        select exists (
            select 1 from vault.decrypted_secrets
            where name = 'supabase_project_url' and nullif(decrypted_secret, '') is not null
        ) into v_project_url_present;
        select exists (
            select 1 from vault.decrypted_secrets
            where name = 'analytics_sync_secret' and nullif(decrypted_secret, '') is not null
        ) into v_sync_secret_present;
        select exists (
            select 1 from vault.decrypted_secrets
            where name = 'google_measurement_enabled' and decrypted_secret = 'true'
        ) into v_measurement_enabled;
    exception when others then
        v_project_url_present := false;
        v_sync_secret_present := false;
        v_measurement_enabled := false;
    end;

    select exists (
        select 1 from cron.job where jobname = 'sync-google-measurement-fifteen-minute' and active
    ) into v_measurement_schedule;
    select exists (
        select 1 from cron.job where jobname = 'sync-google-ads-daily' and active
    ) into v_ads_schedule;

    return jsonb_build_object(
        'project_url_secret_present', v_project_url_present,
        'analytics_sync_secret_present', v_sync_secret_present,
        'measurement_enabled', v_measurement_enabled,
        'measurement_schedule_active', v_measurement_schedule,
        'measurement_reporting', v_measurement_enabled and v_measurement_schedule and v_sync_secret_present,
        'measurement_pending', (select count(*) from public.google_conversion_outbox where status in ('pending', 'failed')),
        'measurement_oldest_pending_at', (select min(created_at) from public.google_conversion_outbox where status in ('pending', 'failed')),
        'measurement_last_transport_accepted_at', (select max(transport_accepted_at) from public.google_conversion_outbox),
        'measurement_last_validated_at', (select max(transport_accepted_at) from public.google_conversion_outbox where validation_status = 'validated'),
        'ads_schedule_active', v_ads_schedule,
        'ads_latest_sync_at', (select max(synced_at) from public.google_ads_campaign_daily),
        'ads_ready', v_ads_schedule and exists (select 1 from public.google_ads_campaign_daily)
    );
end;
$$;

revoke all on function public.google_analytics_sync_readiness() from public, anon, authenticated;
grant execute on function public.google_analytics_sync_readiness() to service_role;
