-- Follow-up to `20260903120558_context_platform_ingestion_control_plane.sql`,
-- fixing what the security/performance advisors flagged after that DDL. Not
-- edited in place, per the rule against touching an applied migration.
--
-- 1. `auth.uid()` in a policy's USING clause runs once per row unless wrapped
--    as `(select auth.uid())`, which lets Postgres evaluate it once per
--    statement (the InitPlan) instead — `auth_rls_initplan`.
-- 2. Three foreign keys had no covering index, which turns their ON DELETE
--    check (and any join through them) into a full scan of the child table.

drop policy "owners read own ingestion jobs" on public.ingestion_jobs;
create policy "owners read own ingestion jobs"
    on public.ingestion_jobs
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy "owners read own source objects" on public.source_objects;
create policy "owners read own source objects"
    on public.source_objects
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy "owners read own source object versions" on public.source_object_versions;
create policy "owners read own source object versions"
    on public.source_object_versions
    for select
    to authenticated
    using (
        exists (
            select 1 from public.source_objects so
            where so.id = source_object_id and so.user_id = (select auth.uid())
        )
    );

drop policy "owners read own source chunks" on public.source_chunks;
create policy "owners read own source chunks"
    on public.source_chunks
    for select
    to authenticated
    using (
        exists (
            select 1 from public.source_objects so
            where so.id = source_object_id and so.user_id = (select auth.uid())
        )
    );

create index source_objects_author_person_idx
    on public.source_objects (author_person_id) where author_person_id is not null;
create index source_object_versions_org_idx
    on public.source_object_versions (org_id) where org_id is not null;
create index source_chunks_org_idx
    on public.source_chunks (org_id) where org_id is not null;
