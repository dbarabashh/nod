# Nod — macOS client

A macOS SwiftUI app that records meetings, transcribes via Whisper (per-chunk,
streaming, through a server-side proxy), and produces summaries via an LLM. It
launches as an accessory (`LSUIElement`) and switches activation policy at
runtime; the primary UI is a floating non-activating panel anchored to the left
of the screen.

## Structure

- `Nod/App/` — composition root + window shell (`NodApp`, `AppServices`, `ContentView`, `FloatingPanel`, `WindowCoordinator`)
- `Nod/Features/<Name>/` — one self-contained product surface per folder
- `Nod/Core/` — shared infrastructure (`Backend`, `Storage`, `LLM`, `Audio`, `Permissions`, `DesignSystem`, `Log.swift`)
- `NodTests/` — unit tests for the pure helpers
- `supabase/` — migrations + Edge Functions (the whole ecosystem's only backend)
- `docs/` — long-form docs; `docs/policies/` — public policy drafts

## Agent context layout

`AGENTS.md` is the canonical instruction file; `CLAUDE.md` is a **symlink** to
it. Edit `AGENTS.md`, never the symlink. Rules and skills live in agent-neutral
directories, with symlinks for Claude Code:

- `.agents/rules/` — topic rules (canonical). `.claude/rules` symlinks to it.
  **Read the relevant rule before editing matching files:**
  - `backward-compatibility.md` (always) — expand/migrate/contract, mixed-version tests, measured legacy retirement
  - `comments.md` (always) — don't write comments; the rare exception is a non-obvious WHY
  - `commits.md` (always) — lowercase, 4–5 words, no AI attribution trailer
  - `swift-architecture.md` (`*.swift`) — where code goes, layering, composition root, no singletons
  - `swift-concurrency.md` (`*.swift`) — `@MainActor` defaults, structured concurrency, the real-time audio-thread constraint
  - `swiftui.md` (`*.swift`) — state-property choice, body performance, no `@Observable` (macOS 13 target)
  - `swift-style.md` (`*.swift`) — naming, error handling, anti-patterns, no force unwraps
  - `design-system.md` (`*.swift`) — SF Symbols only, reuse `Core/DesignSystem`, match standard macOS UX
  - `logging.md` (`*.swift`) — `Log.<area>`, never `print`
  - `apple-apis.md` (`*.swift`) — verify framework APIs via the sosumi MCP, not from memory
  - `xcode-project.md` (`project.yml`, `*.pbxproj`) — edit `project.yml` + `xcodegen generate`, never the pbxproj
  - `supabase.md` (`supabase/**`) — CLI + migrations only, never the dashboard
  - `policies.md` (`docs/policies/**` and bound code) — flag the policy when the code it describes changes
  - `docs-reality.md` (`PLAN.md`, `README.md`, `docs/**`) — docs describe what the code does, not what we hope
  - `README.md` — format for writing new rules
- `.agents/skills/` — skills in the `SKILL.md` [Agent Skills](https://agentskills.io)
  format (canonical). Codex and other standard-following tools discover this
  directory natively; Claude Code loads them via per-skill symlinks in
  `.claude/skills/`. When adding a skill, put it in `.agents/skills/<name>/` and
  add a matching symlink in `.claude/skills/`.
- `.agents/hooks/` — shared hook scripts. Claude Code calls them from
  `.claude/settings.json`; Codex calls them from `.codex/hooks.json`. Keep both
  adapters behaviorally equivalent when a shared hook changes.

Tool-specific adapters stay in `.claude/` and `.codex/`; required behavior must
live in `AGENTS.md` or `.agents/`, never only in a plugin or one tool's config.
Keep `.mcp.json` and `.codex/config.toml` aligned for shared project MCP servers.
The ecosystem contract is documented in
`../nod-playbook/context/agent-tooling.md`.
`CONVENTIONS.md` is now an index that points into `.agents/rules/`.

## Nod knowledge contract

`nod-playbook` is the ecosystem source of truth for product context and durable
decisions. For every new or materially changed feature:

1. Locate the `nod-playbook` checkout (normally `../nod-playbook`; from a
   worktree, locate the workspace's checkout by repository name) and read
   `LLMS.md`, `context/README.md`, `context/features/README.md`, the existing
   feature record and related decisions before implementation.
2. In the same work item as the code, create or update one indexed feature
   record and update broader context owners only when their facts changed.
3. Add or supersede a decision record for choices that change product
   boundaries, privacy, retention, entitlements, shared schemas or APIs,
   cross-repo contracts, or costly-to-reverse architecture.
4. Run the playbook's `./scripts/validate.sh` and report the playbook files in
   the final handoff.

This repo remains authoritative for implementation details. Do not copy them
into the playbook. If the playbook is unavailable or read-only, report that as
a completion blocker instead of silently skipping the update.

## Commands

```sh
xcodegen generate                                          # after adding/removing files or editing project.yml
xcodebuild -project Nod.xcodeproj -scheme Nod build        # CLI build
xcodebuild -project Nod.xcodeproj -scheme Nod -destination 'platform=macOS' test
```

**First clone:** fetch the VAD payload before the first build — it is not
committed, and the build fails without it:

```sh
./scripts/fetch-vad-xcframework.sh     # sherpa-onnx VAD xcframework → Vendor/
```

Full build, lint/format, git-hook, and CI-pin details: `docs/build-setup.md`.

## Where things are documented

| Topic | Doc |
|---|---|
| Build, VAD setup, lint/format/CI pins, logs | `docs/build-setup.md` |
| Audio pipeline, panel, permissions, entry flow, config, in-flight changes | `docs/architecture.md` |
| Supabase CLI, sandbox/prod branching, PAT gotchas | `docs/supabase.md` |
| Integration broker (Pipedream Connect), app manifests, environments | `supabase/integrations/README.md` |
| Sibling repos and cross-repo invariants | `docs/ecosystem.md` |
| Which policy to update when code changes | `docs/policy-bindings.md` |
| Release pipeline (Sparkle, notarization, appcast) | `docs/release.md` |
| Pricing model | `docs/pricing.md` |
| Product context, feature records and durable decisions | `nod-playbook` (`LLMS.md`) |

## Backend

One Supabase project serves the whole ecosystem — prod ref
`lptqvnizjwglilgeukwx`, sandbox branch `zdpvmwqauczsfwlgflas`, selected by build
config (`#if DEBUG` → sandbox). Provider keys never ship in the bundle: the
client knows the `llm-proxy` URL and the user's JWT, nothing more.

## Issue tracker

Work is tracked as GitHub issues at <https://github.com/dbarabashh/Nod/issues>
with explicit dependency chains — check a ticket's "Blocked by" before starting
it. The original launch-plan critical path was **#1 → #10 → #11 → #14 → #17 →
#18** (auth → LLM proxy → meeting persistence → free tier → Paddle); larger
epics also live in the Linear `NOD` project.

There is no `PLAN.md` in this repo — earlier agent instructions referenced one
that was never committed. Don't cite it; read the issues instead.

## MCP servers

`.mcp.json` ships three servers:

- **sosumi** — Apple Developer Documentation; use it instead of recalling API
  signatures.
- **supabase-sandbox** — the `develop` branch (`zdpvmwqauczsfwlgflas`),
  read-write. Development goes here.
- **supabase-prod** — production (`lptqvnizjwglilgeukwx`), **`read_only=true`**.
  It answers questions about live schema and data; it cannot change them.

Both Supabase servers are named for their environment on purpose — there is no
bare `supabase`, so no call reaches an environment by default. Writing to
production is a deliberate act performed outside this config (Supabase CLI with
the `sbp_` PAT), never a tool call that looked routine.


## Paddle integration

When writing or modifying code that integrates with Paddle:

- Always check current Paddle documentation before suggesting code. Prefer the
  `paddle-docs` MCP server when available; otherwise browse official Paddle
  documentation. The Paddle API and SDKs evolve frequently — do not rely on
  training data alone.
- Use the official Paddle SDK for the language in use:
  - Node.js → `@paddle/paddle-node-sdk`
  - Python → `paddle-python-sdk` (imports as `paddle_billing`)
  - Go → `github.com/PaddleHQ/paddle-go-sdk/v5`
  - PHP → `paddlehq/paddle-php-sdk`
- All development uses the sandbox environment. Sandbox API keys contain `_sdbx`; sandbox client-side tokens are prefixed with `test_`.
- Always verify webhook signatures before acting on the payload:
  - Node: `paddle.webhooks.unmarshal()`
  - Python: `Verifier().verify(request, secret)`
  - Go: `paddle.NewWebhookVerifier()` with `Middleware`
  - PHP: `(new Verifier())->verify($request, $secret)`
- For destructive account changes (updating prices, archiving products, canceling subscriptions), ask for explicit confirmation before calling the `paddle-sandbox` or `paddle-live` MCP server.
- Use `paddle-sandbox` by default. Only call `paddle-live` when the prompt explicitly mentions live, production, or real customer data.
- API keys and webhook secrets live in environment variables — never inline credentials into code.
