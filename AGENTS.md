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

Claude-only config (`.claude/settings.json` hooks) stays in `.claude/`.
`CONVENTIONS.md` is now an index that points into `.agents/rules/`.

## Commands

```sh
xcodegen generate                                          # after adding/removing files or editing project.yml
xcodebuild -project Nod.xcodeproj -scheme Nod build        # CLI build
xcodebuild -project Nod.xcodeproj -scheme Nod -destination 'platform=macOS' test
```

**First clone:** run both fetch scripts before the first build — neither payload
is committed, and the build fails without them:

```sh
./scripts/fetch-vad-xcframework.sh     # sherpa-onnx VAD xcframework → Vendor/
./scripts/fetch-diarization-models.sh  # the two diarization ONNX models → Nod/Core/Resources/
```

Full build, lint/format, git-hook, and CI-pin details: `docs/build-setup.md`.

## Where things are documented

| Topic | Doc |
|---|---|
| Build, VAD setup, lint/format/CI pins, logs | `docs/build-setup.md` |
| Audio pipeline, panel, permissions, entry flow, config, in-flight changes | `docs/architecture.md` |
| Supabase CLI, sandbox/prod branching, PAT gotchas | `docs/supabase.md` |
| Sibling repos and cross-repo invariants | `docs/ecosystem.md` |
| Which policy to update when code changes | `docs/policy-bindings.md` |
| Release pipeline (Sparkle, notarization, appcast) | `docs/release.md` |
| Pricing model | `docs/pricing.md` |

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

`.mcp.json` ships two project-scoped servers: **sosumi** (Apple Developer
Documentation — use it instead of recalling API signatures) and **supabase**
(pointed at the prod project ref).
