---
description: Structured-concurrency rules, actor isolation, and the real-time audio-thread constraint.
globs: '*.swift'
alwaysApply: false
---

- Never `await`, allocate unboundedly, or block inside an audio callback. Buffers arrive on real-time threads (`AVAudioEngine` tap, `SCStream` output queue) — forward synchronously to a dedicated `DispatchQueue`. See `AudioCaptureService` and `WhisperTranscriber` for the pattern.
- Mark UI and service objects `@MainActor` by default — the isolation makes `@Published` mutations safe for free.
- Use structured concurrency only: `Task { ... }` with `await` for background work. Never `DispatchQueue.main.async` from a `@MainActor` context, never `Thread.sleep`.
- Make long-running work cancellable — capture the task handle when the caller may need to stop it.
- Use `nonisolated` only when a callback genuinely cannot hop to an actor. It's an escape hatch, not a default.
- Use `weak self` in escaping closures that cross an actor boundary or outlive the captured object — not everywhere by reflex.
- Never hand-roll threading primitives (locks, semaphores, manual queues for mutual exclusion). Use actors, `@MainActor`, `nonisolated`, and structured `Task`.
