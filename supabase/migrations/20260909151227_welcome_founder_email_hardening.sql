-- Hardening for welcome-founder, from the independent review of 20260909150048.
--
-- Deploy order (this migration and its predecessor):
--   1. `welcome-founder-v1-en` must be PUBLISHED in Resend first. Resend is one
--      account for every environment, and it is already published — but a fresh
--      environment that skips this step queues rows the worker defers with
--      `template_not_published`, and `expires_at` cancels them 30 days later.
--   2. Apply the migrations.
--   3. Deploy `resend-worker` (it carries the sender fix, not the campaign).
-- Rollback: reverting the campaign row leaves `email_outbox_send_guard` without
-- a welcome-founder branch, which cancels every already-queued welcome row
-- rather than leaving it pending. Disable the trigger first, drain the outbox,
-- then revert.
--
-- Known and accepted: while `email_program_config.program_not_before` is null,
-- every queued welcome row expires uncollected after 30 days, and the only
-- enqueue path is the signup trigger. Accounts created before the gate opens
-- therefore never receive the letter. There is deliberately no backfill: one
-- would mail the entire existing user base the moment the gate opened.

create or replace function public.queue_welcome_founder_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_first_name text;
begin
    -- `exception when others` cannot trap query_canceled, so an unrelated
    -- ACCESS EXCLUSIVE lock on the email tables would otherwise block signups
    -- until statement_timeout aborted the INSERT. Give up on the lock instead.
    perform set_config('lock_timeout', '50ms', true);
    -- `user_name` is the key handle_new_user_profile stores, so reading it here
    -- keeps the greeting and profiles.display_name from disagreeing.
    v_first_name := coalesce(
        nullif(split_part(coalesce(new.raw_user_meta_data ->> 'full_name', ''), ' ', 1), ''),
        nullif(split_part(coalesce(new.raw_user_meta_data ->> 'name', ''), ' ', 1), ''),
        nullif(split_part(coalesce(new.raw_user_meta_data ->> 'user_name', ''), ' ', 1), ''),
        nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
        'there'
    );
    perform public.enqueue_transactional_email(
        new.id,
        'welcome-founder',
        'signup:' || new.id::text,
        jsonb_build_object(
            'FIRST_NAME', v_first_name,
            'first_name', v_first_name,
            'APP_URL', 'https://hellonod.app/open?target=record'
        )
    );
    return new;
exception when others then
    raise warning 'queue_welcome_founder_email skipped for %: %', new.id, sqlerrm;
    return new;
end;
$$;

revoke all on function public.queue_welcome_founder_email() from public, anon, authenticated;
