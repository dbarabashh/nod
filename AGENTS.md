# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.
It intentionally mirrors [`CLAUDE.md`](./CLAUDE.md): every repository rule in
`CLAUDE.md` applies here too. When changing agent instructions, keep both files
in sync unless a rule is explicitly tool-specific.

## Project

Nod — a macOS SwiftUI app that records meetings, transcribes via Whisper (per-chunk, streaming), and produces summaries via an LLM. Launches as an accessory (`LSUIElement = YES`, no Dock icon); the only UI is a floating non-activating panel anchored to the left of the screen.

## Build, run, and regenerate

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — **never edit `Nod.xcodeproj` by hand**, edit `project.yml` and regenerate.

```sh
# After adding/removing source files or editing project.yml:
xcodegen generate

# Open in Xcode, then ⌘R:
open Nod.xcodeproj

# CLI build:
xcodebuild -project Nod.xcodeproj -scheme Nod build

# CLI tests (when a test target exists — none yet at time of writing):
xcodebuild -project Nod.xcodeproj -scheme Nod test
xcodebuild -project Nod.xcodeproj -scheme Nod test -only-testing:NodTests/MeetingStoreTests/testInsert
```

Targets macOS 13+, Swift 5.9, **universal (Apple silicon + Intel)**. SPM deps: `supabase-swift` v2+, `Sparkle` v2+. The on-device VAD (sherpa-onnx) is a **vendored xcframework, not SPM** — see next section. Bundle ID: `com.example.nod`.

### First-time setup — VAD dependency (required before the first build)

Nod links a vendored, universal (arm64 + x86_64) static build of
**sherpa-onnx** (on-device Silero VAD + bundled onnxruntime) at
`Vendor/sherpa-onnx.xcframework`. It is **not** an SPM package (sherpa-onnx
ships none) and is **not** committed — the universal static lib contains a file
over GitHub's 100 MB limit. Generate it once per clone, before building:

```sh
./scripts/fetch-vad-xcframework.sh   # downloads the pinned sherpa-onnx release, builds the xcframework into Vendor/
xcodegen generate                    # then build / open Nod.xcodeproj as usual
```

- **Build-time only.** The xcframework is statically linked into the app — nothing
  extra is embedded, signed, or shipped. A downloaded `.app` is fully
  self-contained (VAD code + the bundled `silero_vad.onnx` model), so end users
  need none of this.
- The Silero model (`Nod/Resources/silero_vad.onnx`, ~600 KB) **is** committed.
- `scripts/release.sh` runs the fetch step automatically.
- To bump sherpa-onnx: edit `SHERPA_VERSION` + `SHA256` in the script, re-run with `--force`.

### Lint, format, and git hooks

```sh
brew install swiftlint swiftformat        # required for the build phase + pre-commit hook
git config core.hooksPath .githooks       # one-time per clone — enables the pre-commit hook
```

SwiftLint runs as a build phase (`project.yml` → `preBuildScripts`). The
pre-commit hook (`.githooks/pre-commit`) auto-formats staged Swift files with
SwiftFormat, then blocks the commit only on **error-level** SwiftLint
violations in staged files (force-unwrap/cast/try). Configs: `.swiftlint.yml`,
`.swiftformat` — both tuned to `CONVENTIONS.md`.

## Configuration

- **Supabase**: production project ref `lptqvnizjwglilgeukwx` (eu-west-1), linked via `supabase/config.toml`. The client URL + key live in `Nod/Backend/SupabaseConfig.swift`, **switched by build config** — Debug points at the `develop` sandbox branch, Release at production (see "Branches" below). Server-side secrets (incl. `OPENROUTER_API_KEY`) are set via `supabase secrets set` — never in the bundle.
- **LLM / Whisper config**: server-side, in the `llm-proxy` Edge Function (`supabase/functions/llm-proxy/`). The client only knows the proxy URL + the user's Supabase JWT; provider routing and the OpenRouter API key live server-side. Chat and Whisper *model* overrides can still be set per-device via `openrouter.model` / `whisper.model` UserDefaults keys — they're forwarded through the proxy in the request payload.
- **User preferences** (persisted in `UserDefaults` under `com.example.nod`):
  - `app.language` — preferred generated-output language for titles, summaries, chat, and meeting metadata (e.g. `"uk"`). Transcription itself stays auto/multilingual and preserves the language actually spoken. Set via the in-app picker; the `defaults write` route is for testing only.
  - `audio.input.deviceUID` — preferred microphone device, set via the UI.

## Working with Supabase

**Always use the Supabase CLI** for anything that touches the Supabase project — schema, functions, secrets, local dev. Don't change things in the dashboard if the change should live in code, and don't hand-roll SQL outside the migrations directory.

Common commands:

```sh
# Schema changes — always via migrations, never via dashboard SQL editor:
supabase migration new <name>            # creates a new timestamped migration file
supabase db push                          # apply local migrations to the linked project
supabase db reset                         # rebuild local DB from migrations (dev only)

# Edge Functions — source lives in supabase/functions/<name>/:
supabase functions deploy <name>
supabase functions serve <name>           # local dev with hot reload

# Secrets (server-side env vars used by Edge Functions):
supabase secrets set OPENROUTER_API_KEY=sk-or-v1-...
supabase secrets list

# Local dev stack:
supabase start
supabase stop
```

The project is already linked (`supabase/config.toml`) to ref `lptqvnizjwglilgeukwx`, so CLI commands target the right project automatically.

### Branches — sandbox (`develop`) vs production (`main`)

We use [Supabase Branching](https://supabase.com/docs/guides/deployment/branching) (Pro plan) to keep development off live data. Two long-lived branches, each a **fully isolated instance** — its own database, Edge Functions, API keys, secrets, and auth config:

| | git branch | Supabase ref | URL | Paddle |
|---|---|---|---|---|
| **Production** | `main` | `lptqvnizjwglilgeukwx` | `api.hellonod.app` (custom domain) | live |
| **Sandbox (dev)** | `develop` (persistent) | `zdpvmwqauczsfwlgflas` | `https://zdpvmwqauczsfwlgflas.supabase.co` | sandbox |

- **The client picks the environment by build config.** `SupabaseConfig` is `#if DEBUG` → the `develop` branch (sandbox), `#else` → production. A Debug build exercises the whole stack — auth, billing, LLM proxy — against sandbox data without ever touching live.
- **Deploys are git-driven.** Pushing to a branch's git branch (for `develop`, via its open PR) makes Supabase apply new **migrations** and deploy **changed Edge Functions** to that branch's instance. Caveat seen in practice: it only redeploys functions whose files changed and has missed one — the deterministic fallback is `SUPABASE_ACCESS_TOKEN=sbp_… supabase functions deploy <name> --project-ref zdpvmwqauczsfwlgflas`.
- **Nothing is inherited from prod automatically.** Secrets (`PADDLE_API_KEY`, `PADDLE_WEBHOOK_SECRET`, `OPENROUTER_API_KEY`, …) and **OAuth providers** (Google) must be set **per branch**. `SUPABASE_URL`/`ANON_KEY`/`SERVICE_ROLE_KEY` are auto-injected. For Google sign-in on a branch you must also add the branch's `…supabase.co/auth/v1/callback` to the Google Cloud OAuth client and allowlist `nod://auth-callback` in the branch's auth URL config.
- **Environment-specific DATA is seeded per branch, not via migrations.** Values that differ between sandbox and live — notably `plan_prices.paddle_price_id` — are set with a one-off `UPDATE` against each branch (migrations only seed `pri_REPLACE_*` placeholders), so sandbox price ids never ship to prod.

**CLI gotcha:** management commands (`secrets set`, `branches …`) read a **Personal Access Token** (`sbp_…`), not the `supabase login` keychain session — pass it inline and target a branch with `--project-ref`:

```sh
SUPABASE_ACCESS_TOKEN=sbp_… supabase secrets set --project-ref zdpvmwqauczsfwlgflas KEY=value
SUPABASE_ACCESS_TOKEN=sbp_… supabase branches update develop --git-branch develop --experimental
```

## Logs

All app logs flow through `Nod/Log.swift` — namespaced by subsystem (`Log.ui`, `Log.audio`, `Log.stt`, `Log.llm`), backed by `os.Logger` with subsystem `com.example.nod`. Each call also mirrors to stdout for Xcode's console. Filter externally with:

```sh
log show --predicate 'subsystem == "com.example.nod"' --last 5m
```

**Do not introduce `print(...)` in new code** — use the matching `Log.<area>.info/error` so output stays filterable.

## Apple documentation (sosumi MCP)

This repo ships a project-scoped MCP server, **sosumi** (`.mcp.json` → `https://sosumi.ai/mcp`), that serves Apple Developer Documentation. Since Nod leans heavily on Apple frameworks (`AVAudioEngine`, `ScreenCaptureKit`/`SCStream`, `AppKit`/`NSPanel`, TCC/permissions, EventKit), **use it instead of guessing or relying on stale training data** whenever you need to confirm an Apple API's signature, availability, semantics, or recommended usage:

- `mcp__sosumi__searchAppleDocumentation` — find the right symbol/page.
- `mcp__sosumi__fetchAppleDocumentation` — read a specific doc page.
- `mcp__sosumi__fetchAppleVideoTranscript` — pull a WWDC session transcript.

Reach for it before writing non-trivial framework code, when an API may be version-gated (macOS 13+ target), or when behavior is surprising — verify against the docs rather than assuming.

## Architecture — the parts you can't infer from the file tree

### Entry flow

`NodApp` is a near-empty SwiftUI `App`; the real bootstrap is in `AppDelegate.applicationDidFinishLaunching` (`Nod/NodApp.swift`). It constructs every service exactly once, wires them together, then either shows the onboarding window or the floating panel based on `OnboardingState.isCompleted`. Services are passed downstream via `@EnvironmentObject`.

### Audio pipeline (the hot path)

The data flow that produces a transcript:

1. **`AudioCaptureService`** captures two independent streams simultaneously: microphone (`AVAudioEngine` with `installTap`) and system audio (`SCStream` via `ScreenCaptureKit`). Both are required for a dialogue transcript. Mic device can be overridden via `preferredInputUID` (persisted to UserDefaults). System audio capture needs Screen Recording TCC permission — that's why the app prompts for it despite "only" wanting audio.
2. **`TranscriptStore`** owns two `WhisperTranscriber` instances tagged `.me` and `.them`, and forks the mic / system buffers into them respectively. Emits `TranscriptEntry`s for live UI.
3. **`WhisperTranscriber`** normalizes incoming buffers to 16 kHz mono Float32 via a cached `AVAudioConverter` and feeds them to an on-device **Silero VAD** (sherpa-onnx, `SherpaVAD.swift`). The VAD detects whole speech segments — start at speech onset, end after a natural pause — so each chunk is a complete utterance cut on a real silence, never mid-word. Each emitted segment is POSTed as a 16-bit PCM WAV through `OpenRouterClient.transcribe(...)` and surfaces as one `TranscriptEntry`. Segmentation is owned by the VAD config in `makeVAD()`: `minSilenceDuration` (the pause that closes a segment), `minSpeechDuration` (drops sub-blips like "um"), and `maxSpeechDuration` (a safety cap so a non-stop talker still streams and chunks stay within Whisper's window). The VAD also subsumes the old "skip silence so Whisper doesn't hallucinate 'Thanks for watching!'" gate — it simply emits no segment for silence.
4. Transcription requests intentionally omit a fixed `language` and `prompt` so Whisper can auto-detect mixed-language speech within a meeting without being nudged toward a prior chunk's language or wording. The language picker controls generated output (summary, title, chat default) and the meeting's stored language code, not a hard STT lock.

### Floating-panel UX

`FloatingPanel` (a `NSPanel` subclass) uses `.nonactivatingPanel | .borderless`, `.floating` window level, `canJoinAllSpaces | stationary | fullScreenAuxiliary | ignoresCycle` collection behavior. This is what makes the panel survive Spaces switches, stay above other windows, and never steal focus. Don't change these flags casually — they're the whole reason the panel UX feels right.

### Permissions

`PermissionManager` handles mic + screen recording. Notable patterns:

- Screen Recording's TCC API doesn't distinguish `notDetermined` from `denied`, so `PermissionManager` synthesizes the distinction with a persisted "we've prompted before" flag (`permissions.screenRecording.prompted`).
- The manager listens to `NSApplication.didBecomeActiveNotification` and re-checks status — this auto-refreshes the UI when the user returns from System Settings.
- Deep links to the correct Settings pane via `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` (and `Privacy_Microphone`).
- After granting Screen Recording, `ScreenCaptureKit` won't pick up the new TCC entry until the app process restarts. The onboarding flow exposes a "Quit & Relaunch" button for this — see issue [#3](https://github.com/dbarabashh/Nod/issues/3).

### Language model

`LanguagePreference` is a user-facing output-language preference, not a transcription constraint. Keep `WhisperTranscriber` auto/multilingual so recruiter-style flows work: a Portuguese interview can include an English assessment block, the transcript preserves the English, and the LLM can later evaluate the candidate's English from the original passages.

## Plan and issue tracker

**`PLAN.md` is the source of truth for what's being built when** — a 90-day launch plan with architectural decisions, weekly goals, and explicit out-of-scope lists. Read it before proposing scope changes.

The plan has been broken into 18 GitHub issues at <https://github.com/dbarabashh/Nod/issues>, labeled `needs-triage`, with explicit dependency chains. Critical path: **#1 → #10 → #11 → #14 → #17 → #18** (auth → LLM proxy → meeting persistence → free tier → Paddle). When working on a ticket, check its "Blocked by" section before starting.

Notable in-flight architecture changes the code doesn't yet reflect:

- **LLM proxy migration (#11)** — `OpenRouterClient` currently calls OpenRouter directly with a client-side key (`UserDefaults: openrouter.apiKey`). The planned target is a Supabase Edge Function (`supabase/functions/llm-proxy/`) that takes a Supabase JWT, forwards to OpenRouter server-side, and enforces per-`user_id` quota at the proxy. Until #11 ships, the direct-OpenRouter path stays.
- **Calendar removal (#8)** — `Nod/Calendar/UpcomingMeetingService.swift` (EventKit-based) and all its wiring in `NodApp` + `ContentView` are scheduled for deletion. Don't add features on top of it.
- **Multilingual expansion (#12)** — `LanguagePreference` now covers the supported output languages, while STT runs auto/multilingual so code-switched speech is preserved in the transcript.
- **Meeting persistence (#14)** — meetings will be stored in a Supabase `meetings` table from day 1 (no local JSON), with soft delete + 30-day trash (#16).

## Policies and trust documents

Public-facing policy drafts live in [`docs/policies/`](./docs/policies/) —
Security, Privacy, Terms, Consent, Subprocessors, plus a `README.md` index.
They mirror what the marketing site at `nod.app/policies` will ship. Every
claim is **tied to specific code in this repo**, so when you touch a piece of
code listed below, proactively flag that the matching policy needs updating —
even if the user didn't ask for the doc update. Bump the `_Last updated:_`
line whenever you edit a policy.

Current status (declared in every policy header): Nod is in **private beta**,
operated by **Dima Barabash as an individual developer** — no company is
incorporated yet, no SOC 2 process started, no per-jurisdiction governing-law
set. All contact emails resolve to `dbarabashdev@gmail.com`.

Code → doc binding cheat-sheet:

| What changed in code/infra | Update in `docs/policies/` |
|---|---|
| New/changed subprocessor (third-party API, OAuth provider, billing, analytics) | `subprocessors.md`, `privacy.md` § 3/5/6 |
| Audio is ever persisted (today: never; `WhisperTranscriber` discards chunks) | `security.md` "Audio recordings", `privacy.md` § 3.2 |
| OpenRouter privacy toggles flipped (ZDR off, "may train on request data" enabled, first-party endpoints re-enabled) | `security.md` § Model training, `privacy.md` § 4 |
| New table in `public.*` schema, or RLS dropped on any table | `security.md` "Infrastructure", `privacy.md` § 3 |
| SSL enforcement disabled (`supabase --experimental ssl-enforcement get`), TLS version downgraded | `security.md` "Trust at a glance" + "Infrastructure" |
| Soft-delete window changed from 30 days, or the `purge-trashed-meetings` pg_cron job removed | `security.md` "Access control", `privacy.md` § 7 |
| Backup retention changes (Supabase plan upgrade, PITR enabled) | `security.md` "Infrastructure", `privacy.md` § 7 |
| Analytics SDK added (PostHog, Sentry, Amplitude, etc.) | `privacy.md` § 3.5 "What we do not collect" (this list must stay accurate), `subprocessors.md` |
| OpenRouter key path changes (any client-side fallback, alternative proxy, new edge function) | `security.md` "Infrastructure" last bullet |
| Google OAuth scopes expanded beyond openid/email/profile (in `AuthService.signInWithGoogle`) | `privacy.md` § 3.1 |
| Consent disclaimer body changes (`ConsentStrings.swift`) | `consent.md`, `privacy.md` § 3.3; also bump `ConsentPreference.disclaimerVersion` |
| Nod incorporates as a company | **every file** — replace "Dima Barabash, individual developer" with entity name + address, fill governing-law and supervisory-authority sections, bump "Last updated", give existing users 30-day notice |
| Paid tier launches (Paddle wired up) | `terms.md` § 7, `subprocessors.md` Paddle row moves out of "planned" |

## Conventions

**Read [`CONVENTIONS.md`](./CONVENTIONS.md) before adding non-trivial Swift code.** It covers the architecture layering, concurrency rules (when `@MainActor`, when `nonisolated`, audio-thread constraints), SwiftUI state-property patterns, naming, error handling, and a list of anti-patterns we explicitly avoid (single-conformer protocols, `Manager`/`Helper` suffixes, force unwraps, etc.).

Short version of what's there:

- **Plan documents reality.** When editing `PLAN.md`, every claim must match what the code does (or what a `- [ ]` task will make it do). No aspirational marketing language — see [memory `feedback-plan-matches-codebase`](#).
- **Match standard UX patterns** for non-differentiating surface (auth, settings, paywall). If 3+ peer apps converge on a pattern, that's the pattern. Reserve design effort for actual product decisions.
- **No comments unless they explain a non-obvious WHY.** Code talks through good names, not narration. Don't restate what the next line does, don't mark fixes/tasks/callers, don't add section headers. See [`CONVENTIONS.md` § Comments](./CONVENTIONS.md#comments).
- **Logging via `Log.<area>`**, not `print`. See above.
- **No edits to `Nod.xcodeproj`** — change `project.yml` and run `xcodegen generate`.
- **Supabase changes via CLI**, not dashboard — see above.
- **Commit messages**: all lowercase, max 4–5 words, no `Co-Authored-By` trailers (no AI attribution). Examples: `add llm proxy edge function`, `fix screen recording prompt`, `drop en/uk language constraint`. **Do not** include any AI-generated `Co-Authored-By: ...` line (Codex, Claude, or other tools) — strip it.
