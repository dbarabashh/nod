-- Rollback for 20260602120400_add_session_embeddings.sql
-- Drops the RPC, the embeddings table, and narrows the usage check back.
-- meetings / transcripts are untouched.
-- WARNING: destroys all stored embeddings (re-indexing requires re-embedding
-- every session).

drop function if exists public.match_session_chunks(vector(1536), int);
drop table if exists public.session_embeddings cascade;

-- Narrow the usage kind back. Remove any embed rows first so the stricter
-- constraint can be re-applied.
delete from public.usage_events where kind = 'embed';
alter table public.usage_events drop constraint usage_events_kind_check;
alter table public.usage_events add constraint usage_events_kind_check
    check (kind in ('chat', 'transcribe'));

-- The `vector` extension is left installed — other objects may rely on it and
-- dropping an extension is rarely what you want on rollback. To remove it
-- manually once nothing uses it: `drop extension if exists vector;`
