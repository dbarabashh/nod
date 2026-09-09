-- The screen-context lookup recomputed the text vector per row.
--
-- `screen_observations` carries a GIN index on `to_tsvector('simple', content)`,
-- but the lookup also orders by `observed_at` and takes a dozen rows, so the
-- planner walks `screen_observations_recent_idx` and evaluates the expression
-- on every row it passes. With terms that match a recent row that is a few
-- dozen evaluations; with terms that match nothing it is every live row the
-- person has — 20k of them at 2.5 KB each — and the statement timeout (8 s)
-- fired before the answer's chat call could even start. The person heard the
-- acknowledgement, then silence, then the answer.
--
-- A stored vector makes the filter a comparison instead of a parse, and gives
-- the planner a column whose selectivity it can estimate, so a rare term goes
-- through the GIN index and a common one stays on the recency index. The
-- expression index stays for the clients that still query the expression;
-- it goes once none do.

alter table public.screen_observations
    add column if not exists content_tsv tsvector
        generated always as (to_tsvector('simple', content)) stored;

create index if not exists screen_observations_content_tsv_idx
    on public.screen_observations using gin (content_tsv);
