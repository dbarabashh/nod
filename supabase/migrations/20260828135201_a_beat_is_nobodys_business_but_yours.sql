-- Postgres grants EXECUTE to the PUBLIC pseudo-role on every new function, and
-- `anon` inherits it. `20260805082210` revoked the *default privileges* for
-- `anon` and `authenticated`, which does not touch PUBLIC — so the two
-- functions that landed with `beats` were callable without signing in.
--
-- Neither leaks: `claim_beat_run` raises on a null `auth.uid()` and
-- `next_beat_run` is arithmetic over its own arguments. But a signed-out caller
-- reaching a `SECURITY DEFINER` function at all is the thing
-- `.agents/rules/supabase.md` names, and the linter flags it on every run until
-- it is closed.
revoke all on function public.claim_beat_run(uuid) from public, anon;
revoke all on function public.next_beat_run(text, smallint, smallint, smallint, text, timestamptz) from public, anon;

grant execute on function public.claim_beat_run(uuid) to authenticated;
grant execute on function public.next_beat_run(text, smallint, smallint, smallint, text, timestamptz) to authenticated;
