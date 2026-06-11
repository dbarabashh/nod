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

- [ ] **Dedup tests** — `TranscriptStore.isAcousticBleed` / `wordSet`
      (`Nod/Audio/TranscriptStore.swift:215-242`). Cases: Jaccard ≥ 0.7 match,
      containment match (short near-subset of long), short-blip guard
      (`dedupMinContainmentWords`), genuine cross-talk that must NOT match.
      Both audio environments matter: speakers (echo present) and headphones
      (no echo) — see the dedup regression history.
- [ ] **JSON extraction tests** — `OpenRouterClient.extractJSON`
      (`Nod/LLM/OpenRouterClient.swift:197-215`). Cases: bare object, fenced
      object, fenced + trailing prose, `​```JSON` uppercase hint, array
      payload, garbage passthrough.
- [ ] **Retry classification tests** — `OpenRouterClient.isTransient` +
      `retryDelayMillis` (`Nod/LLM/OpenRouterClient.swift:221-247`).
      429/5xx/networkFailed → transient; 4xx/decoding/auth → not; 429 and 546
      get the 800ms base, others 400ms, doubling per attempt.
- [ ] **Error-body sanitizer tests** — `OpenRouterClient.sanitizeErrorBody`
      (`Nod/LLM/OpenRouterClient.swift:536-575`). HTML page → title extract,
      proxy `{"error": "..."}`, OpenRouter `{"error": {"message", "metadata"}}`,
      length caps.
- [ ] **Refresh merge tests** — extract the draft-preserving merge inside
      `MeetingStore.refresh` (`Nod/Storage/MeetingStore.swift:502-508`) into a
      pure internal `static func merging(rows:drafts:)` and test: draft kept
      when absent from server rows, replaced when present, newest-first sort
      stable. (The extraction itself is part of this task — it is a pure code
      move.)

## Phase 1 — mechanical cleanups (low risk)

- [ ] **`Meeting` copy helper.** Add `func with(deletedAt: Date??) -> Meeting`
      (or a narrow `updating`-style helper matching the existing one) and
      replace the two full-init copies in `MeetingStore.softDelete` /
      `restore` (`Nod/Storage/MeetingStore.swift:313-327, 348-361`). Field set
      must stay identical — a missed field here IS a behavior change.
- [ ] **Generation kind enum.** Replace stringly-typed
      `generate(kind: String)` / `isGenerating(for kind: String)`
      (`Nod/ContentView.swift:364, 564`) with a small internal enum. Raw
      values keep the current strings so any log lines stay greppable.
- [ ] **UserDefaults key constants.** Gather the scattered raw keys
      (`openrouter.model`, `openrouter.model.fallback`, `whisper.model`,
      `share.viewerBaseURL`, `audio.input.deviceUID`, …) into one enum of
      constants. **Keys themselves must not change** — they are persisted
      user state.
- [ ] **`HotkeyManager.shared` → injected instance.** Conventions ban
      singletons; construct it in `applicationDidFinishLaunching` and pass it
      where `HotkeyManager.shared` is used today (`Nod/NodApp.swift:62, 712`,
      ContentView, SettingsView). Carbon hotkey registration must happen at
      the same point in the launch sequence as it does now — verify the
      toggle-panel and suggest-reply hotkeys still fire before onboarding
      completes.

## Phase 2 — concurrency hardening

Goal: same observable pipeline output, but the invariants move from comments
("must be called on `queue`") into the type system, and the real-time audio
thread stops doing heavy work.

- [ ] **Get VAD work off the real-time thread.**
      `WhisperTranscriber.append` runs normalize + VAD inference + segment
      drain via `queue.sync` on the `AVAudioEngine` tap / `SCStream` callback
      thread (`Nod/Audio/WhisperTranscriber.swift:117-124`). Change to: copy
      the incoming `AVAudioPCMBuffer` (it is only valid during the callback —
      this is why the code is `sync` today), then `queue.async` the existing
      pipeline. The queue is serial, so segment order, prompt-tail chaining,
      and emitted text are unchanged. Verify with a recorded meeting that the
      transcript matches a pre-change run on the same audio.
- [ ] **RT-safe mute flag.** The tap closure reads the `@MainActor`
      `micEnabled` property from the audio thread
      (`Nod/Audio/AudioCaptureService.swift:187`) — a documented but real data
      race. Mirror it into an `OSAllocatedUnfairLock`-guarded (or atomic) flag
      written by `setMicMuted`, read by the tap. The deliberate one-frame
      tolerance on toggle is preserved; only the unsynchronized access goes.
- [ ] **Make the queue discipline structural.** `WhisperTranscriber` is
      `@unchecked Sendable` with hand-enforced queue confinement
      (`promptTail`, `inFlightFlushes`, `chunkCounter`, cached converter).
      Either convert to an `actor` with a `nonisolated` ingest path feeding it,
      or — if the AVAudioConverter/queue interplay makes an actor awkward —
      keep the queue but move all mutable state behind one lock-protected
      container so `@unchecked` can be dropped. Decide after Phase 2 task 1
      lands; do not force the actor shape if it would change flush semantics
      (`flushPending` must still return only after all in-flight segments are
      appended, in order).
- [ ] **Strict-concurrency audit (no committed flag change).** Build once
      locally with `SWIFT_STRICT_CONCURRENCY=complete` and file what it flags
      in `TranscriptStore` (`DispatchQueue.main.async` hops,
      `@unchecked Sendable`) as follow-ups. Fix only what is fixable without
      reordering published updates — `entries`/`liveMe`/`lastError` must keep
      arriving on main in the same order.

## Phase 3 — structural extraction

- [ ] **Extract the meeting lifecycle out of `ContentView`.**
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
- [ ] **De-optional the service graph.** `AppDelegate` holds 20+ optional
      service properties and a 13-line `guard let` wall in `showFloatingPanel`
      (`Nod/NodApp.swift:24-47, 396-408`). Introduce an `AppServices` struct
      whose memberwise init builds everything currently constructed in
      `applicationDidFinishLaunching:131-198`; AppDelegate keeps a single
      `services: AppServices?`. The construction ORDER is load-bearing
      (Supabase before LLM client; `auth.onSignOut` wiring; audio-capture
      callbacks) — move it as one block, don't re-derive it.
- [ ] **Split `AppDelegate` responsibilities.** After the services struct:
      extract window management (`reconcileWindows`, the five
      `show*/close*Window` pairs, `NSWindowDelegate`) into a
      `WindowCoordinator`, and the status item + `NSMenuDelegate` into a
      `StatusItemController`. `NodApp.swift` should end up as bootstrap +
      wiring only. Window reconciliation on sign-out (cache clears at
      `Nod/NodApp.swift:222-235`) must keep firing in the same order relative
      to `stopRecordingServices`.
- [ ] **Narrow the NotificationCenter event bus (optional).**
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
