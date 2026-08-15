-- Running the calendar sweep on a schedule.
--
-- `invoke_internal_edge_job` carries an allowlist rather than accepting any
-- function name, because it is a `SECURITY DEFINER` that reads a bearer secret
-- out of the vault and POSTs it somewhere. The allowlist is the thing that stops
-- that secret being aimed at an arbitrary endpoint, so adding a job means
-- editing it — that friction is the feature.
--
-- Every ten minutes. The number is set by what the sweep is for: knowing which
-- meeting is starting. A meeting moved five minutes before it begins is the case
-- that matters, and an hourly sweep would miss it entirely.

create or replace function public.invoke_internal_edge_job(p_function_name text)
    returns bigint
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_project_url text;
    v_internal_secret text;
    v_request_id bigint;
begin
    if p_function_name not in ('resend-worker', 'billing-jobs', 'calendar-sync') then
        raise exception 'unsupported internal edge job %', p_function_name;
    end if;

    select decrypted_secret into v_project_url
      from vault.decrypted_secrets where name = 'supabase_project_url';
    select decrypted_secret into v_internal_secret
      from vault.decrypted_secrets where name = 'internal_job_secret';
    -- Nothing to do before the operator has configured this branch. Staying
    -- quiet keeps the cron history readable instead of one failure per run.
    if coalesce(v_project_url, '') = '' or coalesce(v_internal_secret, '') = '' then
        return null;
    end if;

    select net.http_post(
        url := rtrim(v_project_url, '/') || '/functions/v1/' || p_function_name,
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_internal_secret,
            'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    ) into v_request_id;
    return v_request_id;
end;
$$;

select cron.schedule(
    'sync-calendars',
    '*/10 * * * *',
    $$select public.invoke_internal_edge_job('calendar-sync')$$
);
