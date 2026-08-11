-- Scheduled workers reach their Edge Function over HTTP, so the shared secret
-- lives in the vault rather than in a migration or a cron command string.
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
    if p_function_name not in ('resend-worker', 'billing-jobs') then
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

revoke all on function public.invoke_internal_edge_job(text) from public, anon, authenticated;
grant execute on function public.invoke_internal_edge_job(text) to service_role;

select cron.schedule(
    'scan-email-candidates-hourly',
    '3 * * * *',
    'select public.scan_email_candidates()'
);

select cron.schedule(
    'run-resend-worker-five-minute',
    '*/5 * * * *',
    $command$select public.invoke_internal_edge_job('resend-worker')$command$
);

select cron.schedule(
    'run-referral-billing-jobs-hourly',
    '11 * * * *',
    $command$select public.invoke_internal_edge_job('billing-jobs')$command$
);

select cron.schedule(
    'measure-email-behavioral-conversions',
    '23 * * * *',
    'select public.measure_email_behavioral_conversions()'
);

select cron.schedule(
    'purge-expired-email-operations',
    '19 3 * * *',
    'select public.purge_expired_email_operations()'
);

-- One call that answers "can this branch send yet", so the rollout checklist is
-- read from the database rather than from memory.
create or replace function public.email_rollout_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_config public.email_program_config%rowtype;
    v_project_url_present boolean := false;
    v_internal_secret_present boolean := false;
    v_schedules integer;
    v_placeholder_prices integer;
begin
    select * into v_config from public.email_program_config where singleton;

    begin
        select exists (
            select 1 from vault.decrypted_secrets
             where name = 'supabase_project_url' and nullif(decrypted_secret, '') is not null
        ) into v_project_url_present;
        select exists (
            select 1 from vault.decrypted_secrets
             where name = 'internal_job_secret' and nullif(decrypted_secret, '') is not null
        ) into v_internal_secret_present;
    exception when others then
        v_project_url_present := false;
        v_internal_secret_present := false;
    end;

    select count(*) into v_schedules
      from cron.job
     where jobname in (
         'scan-email-candidates-hourly',
         'run-resend-worker-five-minute',
         'run-referral-billing-jobs-hourly',
         'measure-email-behavioral-conversions',
         'purge-expired-email-operations'
     );

    select count(*) into v_placeholder_prices
      from public.plan_prices
     where paddle_price_id like 'pri_REPLACE_%'
       and available_for_new_checkout;

    return jsonb_build_object(
        'policy_version', v_config.policy_version,
        'prompt_version', v_config.prompt_version,
        'policy_published_at', v_config.policy_published_at,
        'program_not_before', v_config.program_not_before,
        'gate_open', public.email_program_gate_open(),
        'project_url_secret_present', v_project_url_present,
        'internal_job_secret_present', v_internal_secret_present,
        'scheduled_jobs', v_schedules,
        'schedules_ready', v_schedules = 5,
        'queued_emails', (select count(*) from public.email_outbox where status = 'queued'),
        'pending_contact_syncs', (select count(*) from public.resend_contact_sync where status = 'queued'),
        'exposed_placeholder_prices', v_placeholder_prices
    );
end;
$$;

revoke all on function public.email_rollout_readiness() from public, anon, authenticated;
grant execute on function public.email_rollout_readiness() to service_role;
