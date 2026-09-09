-- The server answers the beats nobody was awake to claim.
--
-- The Mac keeps right of first refusal: `claim_beat_run` is the mutex it has
-- always been, and a machine that is awake claims its run within its own
-- minute tick. Only a run still `due` three minutes past its moment — a shut
-- laptop — is handed to the worker, which answers it with a reduced grounded
-- turn and lets the existing `done` trigger push the phone. A run neither the
-- Mac nor the worker answered still expires exactly as before, so turning the
-- worker off restores yesterday's behaviour to the letter.

create or replace function public.claim_stale_beat_runs(p_limit integer default 5)
returns table (
    run_id uuid,
    beat_id uuid,
    user_id uuid,
    prompt text,
    title text,
    scheduled_for timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    with stale as (
        select r.id
          from public.beat_runs r
         where r.status = 'due'
           -- Three minutes of grace: an awake Mac's runner ticks every sixty
           -- seconds, so anything still unclaimed here has no Mac behind it.
           and r.scheduled_for < now() - interval '3 minutes'
           -- The expiry window still applies; the worker never resurrects a
           -- run the product has promised to let go.
           and r.scheduled_for > now() - interval '6 hours'
         order by r.scheduled_for
         limit greatest(1, least(p_limit, 20))
           for update skip locked
    )
    update public.beat_runs r
       set status = 'claimed', claimed_at = now()
      from stale
      join public.beats b on true
     where r.id = stale.id
       and b.id = r.beat_id
    returning r.id, r.beat_id, r.user_id, b.prompt, b.title, r.scheduled_for;
end;
$$;

revoke all on function public.claim_stale_beat_runs(integer) from public, anon, authenticated;
grant execute on function public.claim_stale_beat_runs(integer) to service_role;

-- The worker joins the two jobs the vault-secret invoker already serves.
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
    if p_function_name not in ('resend-worker', 'billing-jobs', 'beat-worker') then
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

-- Every five minutes, not every minute: a stale run is by definition one
-- nobody is waiting in front of, and the grace window already costs three.
select cron.schedule(
    'answer-stale-beats',
    '*/5 * * * *',
    $$select public.invoke_internal_edge_job('beat-worker')$$
);
