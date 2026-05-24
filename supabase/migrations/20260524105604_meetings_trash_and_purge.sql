-- Trash UI support: a SELECT policy that exposes the user's own
-- soft-deleted meetings (the original SELECT policy requires
-- `deleted_at IS NULL`, so trashed rows are invisible without this).
-- RLS policies are OR-combined, so:
--   `where deleted_at is null`     → original policy permits
--   `where deleted_at is not null` → new policy permits
-- and a bare `select *` returns both (used by no caller — clients
-- always filter, but defence in depth).
--
-- Plus a nightly pg_cron job that hard-deletes rows older than 30 days
-- — matches the spec ("Items are automatically deleted after 30 days").
--
-- Issue #16 — https://github.com/dbarabashh/Nod/issues/16

create policy "users read own trashed meetings"
    on public.meetings
    for select
    to authenticated
    using (auth.uid() = user_id and deleted_at is not null);

-- Try to enable pg_cron + schedule the purge. Both steps are wrapped in
-- WHEN OTHERS so a project where pg_cron isn't permitted (e.g. local
-- Supabase without the extension, or a plan-tier restriction) doesn't
-- block the rest of this migration. Operator can later run both blocks
-- manually once the extension is available.
do $$
begin
    create extension if not exists pg_cron;
exception when others then
    raise notice 'pg_cron extension unavailable (%) — purge schedule skipped. Enable via the Supabase dashboard, then run cron.schedule(...) manually.', sqlerrm;
end $$;

do $$
begin
    perform cron.schedule(
        'purge-trashed-meetings',
        '0 3 * * *',  -- 03:00 UTC daily
        $cmd$delete from public.meetings
             where deleted_at is not null
               and deleted_at < now() - interval '30 days'$cmd$
    );
exception when others then
    raise notice 'cron.schedule unavailable (%) — purge will not run automatically.', sqlerrm;
end $$;
