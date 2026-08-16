---
description: All Supabase changes go through the CLI and migrations, never the dashboard.
globs: 'supabase/**'
alwaysApply: false
---

- Always use the Supabase CLI for anything touching the project — schema, functions, secrets, local dev. Never make a change in the dashboard that should live in code.
- Follow `backward-compatibility.md` for every schema, RPC, function, enum, and payload change; a migration that applies cleanly can still break a released consumer.
- Test the upgrade from the previous production migration set with both the oldest supported and newest clients; `supabase db reset` against only the final schema is not enough.
- Add new columns, versions, overloads, and accepted values before switching consumers; drop or tighten them only in the separate Linear cleanup issue after its measured retirement gate passes.
- Never hand-roll SQL outside `supabase/migrations/`. Create migrations with `supabase migration new <name>` and apply with `supabase db push`.
- Grant every new function explicitly — `grant execute on function public.<fn>(<args>) to authenticated;` (add `anon` only when the surface is genuinely public). Since `20260805082210` the schema's default privileges grant nothing, so a function without a grant is callable by nobody.
- Revoke from `public`, not just from `anon`. Postgres grants `EXECUTE` to the PUBLIC pseudo-role on every new function, and `anon` inherits it — `revoke ... from anon` alone leaves the function wide open.
- Start every `SECURITY DEFINER` function with its own authorization check (`auth.uid() is null` → raise, or `_assert_founder()`). Grants are the second line of defence, never the first.
- Never fast-forward migrations between `main` and `develop` — each branch's instance keeps its own history and they legitimately diverge. Read `docs/supabase.md` before touching migrations on either branch.
- Never modify an applied migration after a manual repair; capture the repair in a forward migration so a fresh environment and production converge.
- Keep environment-specific data (e.g. `plan_prices.paddle_price_id`) out of migrations — migrations seed `pri_REPLACE_*` placeholders; real ids are set per branch with a one-off `UPDATE`.
- Set every secret per branch — nothing is inherited from prod. Management commands need the `sbp_` PAT inline plus `--project-ref`, not the `supabase login` session.
- Never put a provider API key in the app bundle. Server-side secrets (`OPENROUTER_API_KEY`, Paddle keys) live in Edge Function secrets; the client only knows the proxy URL and the user's JWT.
- Deploy an Edge Function explicitly when git-driven deploys miss it: `supabase functions deploy <name> --project-ref <ref>`.
- Flag the matching policy doc when a change adds a table, drops RLS, or adds a subprocessor — see `.agents/rules/policies.md`.
