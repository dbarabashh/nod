---
description: All Supabase changes go through the CLI and migrations, never the dashboard.
globs: 'supabase/**'
alwaysApply: false
---

- Always use the Supabase CLI for anything touching the project — schema, functions, secrets, local dev. Never make a change in the dashboard that should live in code.
- Never hand-roll SQL outside `supabase/migrations/`. Create migrations with `supabase migration new <name>` and apply with `supabase db push`.
- Never fast-forward migrations between `main` and `develop` — each branch's instance keeps its own history and they legitimately diverge. Read `docs/supabase.md` before touching migrations on either branch.
- Keep environment-specific data (e.g. `plan_prices.paddle_price_id`) out of migrations — migrations seed `pri_REPLACE_*` placeholders; real ids are set per branch with a one-off `UPDATE`.
- Set every secret per branch — nothing is inherited from prod. Management commands need the `sbp_` PAT inline plus `--project-ref`, not the `supabase login` session.
- Never put a provider API key in the app bundle. Server-side secrets (`OPENROUTER_API_KEY`, Paddle keys) live in Edge Function secrets; the client only knows the proxy URL and the user's JWT.
- Deploy an Edge Function explicitly when git-driven deploys miss it: `supabase functions deploy <name> --project-ref <ref>`.
- Flag the matching policy doc when a change adds a table, drops RLS, or adds a subprocessor — see `.agents/rules/policies.md`.
