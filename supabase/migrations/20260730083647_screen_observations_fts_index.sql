-- Carry the screen-observation FTS index across on its own.
--
-- `screen_observations` was created on the sandbox as 20260722220000, then the
-- file was renamed to 20260723120000 and gained this index before prod applied
-- it. The sandbox therefore has the table but not the index, and 20260723120000
-- is now repaired-as-applied there so it will never run — this migration is the
-- only path that delta has.
--
-- `if not exists` because prod already created it under the old version: this
-- must be a no-op there, not a duplicate-index error.
--
-- The config is `simple` on purpose, matching the original: questions and
-- screens are a Ukrainian/English mix, and the `english` stemmer drops Cyrillic
-- terms on the floor. The client must pass the same config or Postgres will not
-- use this index.

create index if not exists screen_observations_content_fts_idx
    on public.screen_observations using gin (to_tsvector('simple', content));
