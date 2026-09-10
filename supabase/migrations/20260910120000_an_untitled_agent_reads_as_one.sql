-- The lock-screen fallback for an untitled agent. `beats` is still the table
-- and `Beat` is still the type; only what a person reads changed, so this
-- replaces the function body and nothing else. The earlier migration stays as
-- it was applied.
--
create or replace function public.notify_beat_answered()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_project_url     text;
    v_internal_secret text;
    v_title           text;
    v_request_id      bigint;
begin
    -- `is distinct from` rather than `<>`: an update that rewrites the row
    -- without moving the status must not send a second notification.
    if new.status is not distinct from old.status
       or new.status <> 'done'
       or new.thread_id is null then
        return new;
    end if;

    -- Nothing to send to. Cheaper to find out here than to wake the function.
    if not exists (select 1 from public.push_tokens where user_id = new.user_id) then
        return new;
    end if;

    select decrypted_secret into v_project_url
      from vault.decrypted_secrets where name = 'supabase_project_url';
    select decrypted_secret into v_internal_secret
      from vault.decrypted_secrets where name = 'internal_job_secret';
    -- Nothing to do before the operator has configured this branch. Staying
    -- quiet keeps the run history readable instead of one failure per run.
    if coalesce(v_project_url, '') = '' or coalesce(v_internal_secret, '') = '' then
        return new;
    end if;

    select b.title into v_title from public.beats b where b.id = new.beat_id;

    -- The beat's name and nothing else. The report itself stays out of the
    -- payload: a lock screen is the one place "only you can read it" stops
    -- being true, and `docs/policies/privacy.md` says it without an asterisk.
    select net.http_post(
        url := rtrim(v_project_url, '/') || '/functions/v1/send-beat-push',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_internal_secret,
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'user_id', new.user_id,
            'beat_id', new.beat_id,
            'run_id',  new.id,
            'title',   coalesce(nullif(btrim(v_title), ''), 'Agent')
        ),
        timeout_milliseconds := 30000
    ) into v_request_id;

    return new;
end;
$$;

revoke all on function public.notify_beat_answered() from public, anon, authenticated;
