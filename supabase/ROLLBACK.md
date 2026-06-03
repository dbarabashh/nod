# Rollback procedure

Every forward migration under `supabase/migrations/` has a paired reverse
script under `supabase/rollback/`. All schema changes in the
profile/kind/chat/entities/RAG work are **additive** — new tables and new
nullable columns only. Nothing renames or drops an existing column, so the
pre-existing `meetings` / `meeting_transcripts` data is never touched by a
rollback.

To take the schema back to a given point, apply the reverse scripts in
**reverse chronological order** (newest first), stopping where you want to
land. Locally:

```sh
# dev: rebuild from migrations, then peel back as needed
supabase db reset
psql "$LOCAL_DB_URL" -f supabase/rollback/<timestamp>_<name>.down.sql
```

On the linked project, run the matching `.down.sql` via the SQL editor or
`psql` against the project connection string. There is no `supabase db pull`
needed — the reverse scripts are self-contained.

## Non-migration changes to revert alongside

- **Edge function** (`llm-proxy`): step 5 added an `embed` route. It's additive
  and harmless if unused, but to fully revert, `git checkout` the function and
  `supabase functions deploy llm-proxy`.
- **`vector` extension**: left installed on rollback (see the step-5 down
  script). Remove manually only once nothing uses it.

> ⚠️ Schema rollback is always safe. **Data created in the new tables
> (profiles, chats, entities, embeddings) is destroyed by the matching drop.**
> Up until real users have stored data, rolling back lands exactly on the
> prior state. After that, a rollback is a data-loss event — treat it as a
> product decision, not just an ops step.

## Steps (newest → oldest)

| Forward migration | Reverse script | Undoes |
|---|---|---|
| `20260603140000_hybrid_retrieval.sql` | `20260603140000_hybrid_retrieval.down.sql` | Batch B — embedding metadata cols, meeting-scoped match RPC, entity-hybrid lookup |
| `20260603120000_embeddings_gte_small.sql` | `20260603120000_embeddings_gte_small.down.sql` | Step 5 fix — re-dimension embeddings to gte-small (384) + user-id-scoped match RPC |
| `20260602120400_add_session_embeddings.sql` | `20260602120400_add_session_embeddings.down.sql` | Step 5 — `session_embeddings`, the match RPC, the widened usage check |
| `20260602120300_add_entities.sql` | `20260602120300_add_entities.down.sql` | Step 4 — `entities` + `meeting_entities` |
| `20260602120200_add_chat_messages.sql` | `20260602120200_add_chat_messages.down.sql` | Step 3 — the `chat_messages` table |
| `20260602120100_add_meeting_kind.sql` | `20260602120100_add_meeting_kind.down.sql` | Step 2 — the `meetings.kind` column |
| `20260602120000_add_profiles.sql` | `20260602120000_add_profiles.down.sql` | Step 1 — the `profiles` table |
