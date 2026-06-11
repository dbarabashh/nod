# Refactor plan — behavior-preserving cleanup

Engineering-only companion to `PLAN.md` (which stays the product plan). This
fixes the code-quality findings from the 2026-06-11 architecture review.

**Hard constraint: zero user-visible behavior change.** Concretely, after every
task the app must keep, byte-for-byte where applicable:

- the same UI, copy, timings, and window/panel behavior;
- the same network payloads and headers to the llm-proxy and PostgREST
  (no field renames, no envelope changes);
- the same persisted data: UserDefaults **keys**, Supabase rows, notification
  names observed by other components;
- the same VAD/segmentation parameters and dedup thresholds;
- the same `Log.<area>` subsystem/category usage (message text may be touched
  only when the code around it moves).

Every task lands as its own commit (or small PR) gated by:

1. `xcodebuild -project Nod.xcodeproj -scheme Nod build` clean;
2. `xcodebuild -project Nod.xcodeproj -scheme Nod test` green;
3. manual smoke: sign in → record a short meeting (mic + system) → live
   transcript appears → end meeting → summary + title generate → meeting shows
   in Library → soft-delete → undo.

Phases are ordered so the test safety net exists before anything moves.

---

## Phase 0 — test safety net

The riskiest logic is pure and untested. Lock its current behavior in tests
*before* refactoring, so phases 1–3 can't silently drift. Where a helper is
`private`, relax to internal (`@testable import Nod` reaches it) — visibility
changes are not behavior changes.

- [x] **Dedup tests** — `TranscriptStore.isAcousticBleed` / `wordSet`
      (`Nod/Audio/TranscriptStore.swift:215-242`). Cases: Jaccard ≥ 0.7 match,
      containment match (short near-subset of long), short-blip guard
      (`dedupMinContainmentWords`), genuine cross-talk that must NOT match.
      Both audio environments matter: speakers (echo present) and headphones
      (no echo) — see the dedup regression history.
- [x] **JSON extraction tests** — `OpenRouterClient.extractJSON`
      (`Nod/LLM/OpenRouterClient.swift:197-215`). Cases: bare object, fenced
      object, fenced + trailing prose, `​```JSON` uppercase hint, array
      payload, garbage passthrough.
- [x] **Retry classification tests** — `OpenRouterClient.isTransient` +
      `retryDelayMillis` (`Nod/LLM/OpenRouterClient.swift:221-247`).
      429/5xx/networkFailed → transient; 4xx/decoding/auth → not; 429 and 546
      get the 800ms base, others 400ms, doubling per attempt.
- [x] **Error-body sanitizer tests** — `OpenRouterClient.sanitizeErrorBody`
      (`Nod/LLM/OpenRouterClient.swift:536-575`). HTML page → title extract,
      proxy `{"error": "..."}`, OpenRouter `{"error": {"message", "metadata"}}`,
      length caps.
- [x] **Refresh merge tests** — extract the draft-preserving merge inside
      `MeetingStore.refresh` (`Nod/Storage/MeetingStore.swift:502-508`) into a
      pure internal `static func merging(rows:drafts:)` and test: draft kept
      when absent from server rows, replaced when present, newest-first sort
      stable. (The extraction itself is part of this task — it is a pure code
      move.)

## Phase 1 — mechanical cleanups (low risk)

- [x] **`Meeting` copy helper.** Added `Meeting.updating(deletedAt:)` and
      replaced the two full-init copies in `MeetingStore.softDelete` /
      `restore`.
- [x] **Generation kind enum.** `GenerationKind: String` in ContentView; raw
      values keep the historical strings (they feed ResponseCard's header
      label and log lines). The now-dead `PromptKind(rawLabel:)` was removed.
      Side effect: ContentView crossed SwiftLint's error-level `file_length`
      cap, so `ResponseCard` + `MiniAction` moved to
      `Nod/Components/ResponseCard.swift` (pure file move, aligns with
      Phase 3).
- [x] **UserDefaults key constants.** *Adjusted from the original "one
      enum" idea:* the codebase convention is per-owner `static let` key
      constants (AppLanguage, OnboardingState, PermissionManager, … all
      already do this), and a central enum would fight the no-Utils-folders
      rule. Fixed the only four inline raw keys instead: `openrouter.model`,
      `openrouter.model.fallback`, `whisper.model` (OpenRouterClient),
      `share.viewerBaseURL` (MeetingStore). Key strings unchanged.
- [x] **`HotkeyManager.shared` → injected instance.** Constructed at the top
      of `applicationDidFinishLaunching` (same point where `.shared` was
      first touched, so Carbon registration timing is identical), injected
      into ContentView via `@EnvironmentObject` and into SettingsView via
      init. Smoke-check the two hotkeys + the menu shortcut display.

## Phase 2 — concurrency hardening

Goal: same observable pipeline output, but the invariants move from comments
("must be called on `queue`") into the type system, and the real-time audio
thread stops doing heavy work.

- [x] **Get VAD work off the real-time thread.**
      `WhisperTranscriber.append` runs normalize + VAD inference + segment
      drain via `queue.sync` on the `AVAudioEngine` tap / `SCStream` callback
      thread (`Nod/Audio/WhisperTranscriber.swift:117-124`). Change to: copy
      the incoming `AVAudioPCMBuffer` (it is only valid during the callback —
      this is why the code is `sync` today), then `queue.async` the existing
      pipeline. The queue is serial, so segment order, prompt-tail chaining,
      and emitted text are unchanged. Verify with a recorded meeting that the
      transcript matches a pre-change run on the same audio.
- [x] **RT-safe mute flag.** The tap closure reads the `@MainActor`
      `micEnabled` property from the audio thread
      (`Nod/Audio/AudioCaptureService.swift:187`) — a documented but real data
      race. Mirror it into an `OSAllocatedUnfairLock`-guarded (or atomic) flag
      written by `setMicMuted`, read by the tap. The deliberate one-frame
      tolerance on toggle is preserved; only the unsynchronized access goes.
- [x] **Make the queue discipline structural.** *Resolved by decision, not
      conversion:* the serial `DispatchQueue` stays. An actor was evaluated
      and rejected — actor isolation does not guarantee FIFO ordering across
      separate `Task` hops, and VAD ingest is order-critical (segments must
      enter Silero in arrival order; `flushPending` must observe a stable
      in-flight set). After the task above, no mutable state is touched
      outside `queue` anymore (the old `append` ran caller-side via
      `queue.sync`; now everything is enqueued), so the queue confinement IS
      the structure. `@unchecked Sendable` stays with that justification.
- [x] **Strict-concurrency audit (no committed flag change).** Built with
      `SWIFT_STRICT_CONCURRENCY=complete` (2026-06-12). Findings, filed as
      follow-ups — none block Swift 5 mode, all are Swift-6-mode errors:
      - `PermissionManager.swift:111` — reference to captured `var self` in
        concurrently-executing code (5×).
      - `EntitlementService.swift:99` — `static let isoFormatter:
        ISO8601DateFormatter` is non-Sendable shared state.
      - `WhisperTranscriber` / `SampleBufferConverter` — the
        `AVAudioConverter` input block captures `fed` (var) and a
        non-Sendable `AVAudioPCMBuffer`; safe in practice (the block runs
        synchronously inside `convert`), needs `@preconcurrency AVFAudio`
        or `nonisolated(unsafe)` when Swift 6 lands.
      - SwiftUI `AttributeScopes` key-path warnings — framework-side noise,
        not ours.

## Phase 3 — structural extraction

- [x] **Extract the meeting lifecycle out of `ContentView`.**
      *Done — notes:* `Nod/Meeting/MeetingSession.swift` now owns the
      lifecycle, generation, and persistence verbatim; ContentView dropped
      from 2022 to ~1300 lines. Two deliberate deviations from the task
      text: (1) the `startMeeting` entitlement/consent gate stayed in the
      view — it manipulates view-modal state (`showConsentDisclaimer`) and
      posts the paywall notification, both presentation concerns; the view
      delegates to `session.beginRecording()` after the gates. (2) the
      session is created **per panel** in `showFloatingPanel`, not once in
      the AppDelegate — the old `@State` died with the panel on sign-out,
      and an app-lifetime session would have leaked a stale REC state into
      the next user's panel.
      `Nod/ContentView.swift` is 2022 lines and owns the whole end-of-meeting
      flow: `startMeeting`, `beginRecording`, `endMeeting`, `persistMeeting`,
      `extractEntities`, `generateMeetingTitle`, `attemptSave`,
      `generate(kind:)`, `cleanupToIdle`, `runSecondsTimer`
      (`Nod/ContentView.swift:351-801`). Move them into a new `@MainActor`
      `ObservableObject` (suggested: `MeetingSession`, in `Nod/Audio/` or a
      new `Nod/Meeting/` folder) constructed in `AppDelegate` and injected via
      `@EnvironmentObject`. ContentView keeps rendering + intent dispatch
      only. The exact orchestration order must survive verbatim:
      `beginGenerating` draft → `.nodOpenMeetingDetail` post → recap/title
      LLM calls → `applyGenerated` → `insert` → `insertTranscript` →
      `indexSession`, including every failure branch
      (`markGenerationFailed`, save-retry toast).
- [x] **De-optional the service graph.**
      *Done* — `Nod/AppServices.swift` with `AppServices.make()`; the
      construction block (and its ordering comments) moved verbatim,
      HotkeyManager stays first so Carbon registration timing is unchanged.
      Both guard walls are gone. `AppDelegate` holds 20+ optional
      service properties and a 13-line `guard let` wall in `showFloatingPanel`
      (`Nod/NodApp.swift:24-47, 396-408`). Introduce an `AppServices` struct
      whose memberwise init builds everything currently constructed in
      `applicationDidFinishLaunching:131-198`; AppDelegate keeps a single
      `services: AppServices?`. The construction ORDER is load-bearing
      (Supabase before LLM client; `auth.onSignOut` wiring; audio-capture
      callbacks) — move it as one block, don't re-derive it.
- [x] **Split `AppDelegate` responsibilities.**
      *Done* — `WindowCoordinator` (windows + reconcile + NSWindowDelegate)
      and `StatusItemController` (status item + NSMenuDelegate);
      `NodApp.swift` is bootstrap + observers only (804 → 245 lines).
      Sign-out still runs `stopRecordingServices` → cache clears → window
      closes → reconcile in the original order inside the auth observer. After the services struct:
      extract window management (`reconcileWindows`, the five
      `show*/close*Window` pairs, `NSWindowDelegate`) into a
      `WindowCoordinator`, and the status item + `NSMenuDelegate` into a
      `StatusItemController`. `NodApp.swift` should end up as bootstrap +
      wiring only. Window reconciliation on sign-out (cache clears at
      `Nod/NodApp.swift:222-235`) must keep firing in the same order relative
      to `stopRecordingServices`.
- [x] **Narrow the NotificationCenter event bus (optional).**
      *Resolved by decision: skipped.* `.nodDeviceConflict` lands in
      AppDelegate, `.nodUpdateRequired` in UpdateGate — replacing them with
      injected callbacks means threading two closures from `AppServices.make`
      into OpenRouterClient: the same coupling through a different mechanism,
      with no behavior gain. The posts are documented at both ends; revisit
      if the observer set grows.
      `OpenRouterClient` posting `.nodDeviceConflict` / `.nodUpdateRequired`
      (`Nod/LLM/OpenRouterClient.swift:512, 521`) is hidden coupling to
      AppDelegate. Replace with injected callbacks set during wiring; keep
      NotificationCenter for genuine UI fan-out (`.nodOpenSettings` & co.,
      which have multiple observers). Skip if Phase 3 review finds the
      callback threading messier than the bus — this one is judgment, not
      principle.

## Explicitly out of scope

- Any UI/UX, copy, or timing change; anything a user could notice.
- New features, dependency bumps, `project.yml` changes beyond adding new
  source files/folders.
- Renaming UserDefaults keys, notification names used across module
  boundaries, Supabase tables/columns/RPCs, or proxy envelope fields.
- Tuning VAD parameters, dedup thresholds, retry counts/delays, or model
  defaults.
- The known in-flight product work (`PLAN.md`, issues #8/#12/#14/#16) — this
  plan must not collide with it; rebase tasks if those land first.
