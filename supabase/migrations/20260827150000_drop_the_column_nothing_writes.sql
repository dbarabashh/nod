-- `evidence_idxs` was added for a multi-turn anchor nothing ever produced: no
-- writer, no reader, and every row null since the day it landed. The single
-- `evidence_idx` and `evidence_quote` are what the loop passes actually use.
--
-- Safe to drop in place rather than through a deprecation window: it has only
-- ever existed on the development branch, no released client encodes it, and
-- the client that stopped sending it ships in the same change.
alter table public.action_items
    drop column if exists evidence_idxs;
