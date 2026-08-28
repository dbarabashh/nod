-- A phone cannot know that a beat was answered.
--
-- The answer is written by a Mac, minutes or hours after anybody last looked at
-- the phone, so there is nothing on the device to notice it. That is the whole
-- reason this exists: it is the only thing in the product that needs a push.
--
-- The send is a trigger rather than a poll, for the same reason `enqueue_due_beats`
-- is cron: the moment a run turns `done` is a fact the database already holds,
-- and a phone asking "is it ready yet" every minute is a battery bill for an
-- answer that arrives twice a day.

create table public.push_tokens (
    user_id     uuid        not null references auth.users(id) on delete cascade,
    -- The same id the device lock uses, so a reinstall replaces its own row
    -- rather than leaving a dead token the sender retries until APNs reports it
    -- unregistered.
    device_id   text        not null,
    token       text        not null,
    platform    text        not null check (platform in ('ios', 'macos')),
    -- A sandbox token handed to the production gateway is rejected as a bad
    -- device token, so the sender has to be told which gateway issued it.
    environment text        not null check (environment in ('sandbox', 'production')),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    primary key (user_id, device_id)
);

create index push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

-- A token is the address of somebody's phone. Every policy is the owner's own,
-- and the sender reaches these through the service role, never through a client.
create policy "users read own push tokens"
    on public.push_tokens for select to authenticated
    using (auth.uid() = user_id);

create policy "users insert own push tokens"
    on public.push_tokens for insert to authenticated
    with check (auth.uid() = user_id);

create policy "users update own push tokens"
    on public.push_tokens for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own push tokens"
    on public.push_tokens for delete to authenticated
    using (auth.uid() = user_id);

-- Fires once, when a run becomes `done` and has a thread to open.
--
-- Not on `failed` and not on `expired`. "Your question went unasked because
-- your Mac was shut" is a worse morning than silence, and the Beats screen
-- already says exactly that when somebody goes looking.
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
    -- quiet keeps the run history readable instead of one failure per beat.
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
            'title',   coalesce(nullif(btrim(v_title), ''), 'Beat')
        ),
        timeout_milliseconds := 30000
    ) into v_request_id;

    return new;
end;
$$;

create trigger beat_runs_notify_answered
    after update on public.beat_runs
    for each row execute function public.notify_beat_answered();

revoke all on function public.notify_beat_answered() from public, anon, authenticated;
