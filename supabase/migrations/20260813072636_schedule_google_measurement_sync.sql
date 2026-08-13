alter table public.google_conversion_outbox
    add column transport_accepted_at timestamptz,
    add column validation_status text not null default 'not_attempted'
        check (validation_status in ('not_attempted', 'not_validated', 'validated', 'rejected'));

create or replace function public.invoke_google_measurement_sync()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_project_url text;
    v_sync_secret text;
    v_request_id bigint;
begin
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

select cron.unschedule(jobid)
from cron.job
where jobname = 'sync-google-measurement-fifteen-minute';

select cron.schedule(
    'sync-google-measurement-fifteen-minute',
    '*/15 * * * *',
    'select public.invoke_google_measurement_sync()'
);

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
    exception when others then
        v_project_url_present := false;
        v_sync_secret_present := false;
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
        'measurement_schedule_active', v_measurement_schedule,
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
