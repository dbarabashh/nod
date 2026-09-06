-- The nightly calendar sweep is allowed to run.
--
-- `20260903082045` rescheduled `sync-calendars` to once a day through
-- `invoke_internal_edge_job('calendar-sync')`, as the safety net under the
-- read-when-asked floors. `invoke_internal_edge_job` allows three job names and
-- `calendar-sync` was never added to them, so the job has raised "unsupported
-- internal edge job" at 04:45 every night since — `cron.job_run_details` shows
-- nothing but failures. The floors carried the product on their own, which is
-- why nobody noticed; the sweep exists for the account whose app has not been
-- opened, and that account has had no read at all.
--
-- The rest of the function is `20260901092036` verbatim.

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
    if p_function_name not in ('resend-worker', 'billing-jobs', 'beat-worker', 'calendar-sync') then
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
