create or replace function public.invoke_google_ads_sync()
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
    if session_user <> 'postgres'
       and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
        raise insufficient_privilege using message = 'service role required';
    end if;

    select decrypted_secret into v_project_url
      from vault.decrypted_secrets where name = 'supabase_project_url';
    select decrypted_secret into v_sync_secret
      from vault.decrypted_secrets where name = 'analytics_sync_secret';

    if coalesce(v_project_url, '') = '' or coalesce(v_sync_secret, '') = '' then
        return null;
    end if;

    select net.http_post(
        url := rtrim(v_project_url, '/') || '/functions/v1/sync-google-ads',
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

revoke all on function public.invoke_google_ads_sync() from public, anon, authenticated;
grant execute on function public.invoke_google_ads_sync() to service_role;

select cron.unschedule(jobid)
from cron.job
where jobname = 'sync-google-ads-daily';

select cron.schedule(
    'sync-google-ads-daily',
    '13 5 * * *',
    'select public.invoke_google_ads_sync()'
);
