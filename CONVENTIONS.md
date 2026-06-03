# Conventions

How we write Swift code in this repo. Read this before adding non-trivial code, and re-read it when you're tempted to introduce a new abstraction.

The defaults: **terse, conventional, pragmatic.** Match Apple's [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) and standard SwiftUI patterns. The opinions below are where we deviate or where the guidelines are silent.

---

## Core philosophy

We optimize for **legibility a year from now** over cleverness today.

- **Don't over-engineer.** Three similar lines beats a premature abstraction. If you introduce a protocol, factory, generic, or wrapper type, it should already have ≥2 callers — not "in case we need it later."
- **Don't pre-validate impossible states.** Trust internal callers and framework guarantees. Only validate at real boundaries: user input, network responses, third-party SDKs returning untyped data. Wrapping a `String` in `guard !string.isEmpty` when the caller is your own code two lines up is noise.
- **No fallbacks for scenarios that can't happen.** If a property is `@MainActor` and the call site is `@MainActor`, you don't need `DispatchQueue.main.async`. If a value type's `init` is total, you don't need to handle a "missing" case.
- **Half-finished is worse than not-started.** If you commit a TODO that says "implement later," at least open an issue and link it. Unowned TODOs rot.

---

## Architecture

**Service composition lives in `AppDelegate.applicationDidFinishLaunching`.** That's the only place we instantiate long-lived services. Services are passed downstream via `@EnvironmentObject`. Avoid singletons (`static let shared`) — make the dependency explicit so tests and previews can swap it.

**Layers, top to bottom:**

1. **Views** (`Nod/*/...View.swift`, `ContentView.swift`) — render state, dispatch user intents. No business logic, no networking.
2. **Stores / Services** (`*Store`, `*Service`, `*Manager`, `*Client`) — own state, encapsulate side effects. Marked `@MainActor` unless they specifically need to be otherwise. Examples: `TranscriptStore`, `AudioCaptureService`, `PermissionManager`, `OpenRouterClient`.
3. **Repositories** (planned: `MeetingStore`) — Supabase access via PostgREST. Async functions, no UI concerns.
4. **Value types** (`Meeting`, `TranscriptEntry`, `UpcomingMeeting`) — `struct` + `Codable` where applicable. Equatable when needed for SwiftUI diffing.

**Default to value types.** Reach for `class` only when you need identity, reference semantics, or `ObservableObject`. `final class` if you do reach for it (we never subclass our own classes).

**One feature per folder.** `Nod/Audio/`, `Nod/Auth/`, `Nod/Storage/`, `Nod/Permissions/`. One file can hold multiple closely-related types (e.g. `TranscriptEntry` + `TranscriptStore` could live together) — don't fragment for the sake of "one type per file."

---

## Concurrency

Swift 5.9, structured concurrency only. No `DispatchQueue.main.async` from `@MainActor` contexts. No `Thread.sleep`.

- **UI + service objects: `@MainActor`** by default. The actor isolation gives you a free guarantee that `@Published` mutations are safe.
- **Background work: `Task { ... }`** with `await`. Long-running work should be cancellable — capture the task handle if the caller needs to stop it.
- **Audio thread is special.** Buffers arrive on real-time priority threads (`AVAudioEngine` tap, `SCStream` output queue). Forward synchronously, do NOT `await` in the callback. See `AudioCaptureService` and `WhisperTranscriber` for the pattern: `nonisolated` reads + a dedicated `DispatchQueue` for chunk accumulation.
- **`nonisolated`** is the escape hatch for thread-safe reads from non-actor contexts. Used today by `LanguagePreference.currentWhisperCode()` so audio threads can read the user's language without hopping to main.
- **`weak self` in escaping closures** crossing an actor boundary or a long-lived service. Don't sprinkle it everywhere — only where the closure outlives the captured object's expected lifetime.

---

## Error handling

- **`throws` is preferred** over `Result<T, E>` for async APIs. Matches the standard library.
- **Define error enums** with `LocalizedError` conformance when the error needs to be shown to the user (see `OpenRouterClient.ClientError`). Otherwise just throw an `NSError` or a small enum without messages.
- **Catch at the boundary, not in the middle.** Repository methods throw, view models catch and convert to a published error state.
- **Don't swallow errors** with `try?` unless you genuinely don't care. If you do, leave a one-line comment explaining why.
- **Network/Supabase errors**: surface to the user as a toast with retry, don't crash. The "meeting save failed → retry?" pattern is the template.

---

## SwiftUI

- **`@StateObject`** when the view *creates* the object. **`@ObservedObject`** when the view *receives* it. **`@EnvironmentObject`** when it's injected up the tree. Mixing these up causes view-update bugs that take hours to find.
- **`@State`** for view-local value-type state. **`@Binding`** to pass write access to a child.
- **Keep view bodies small.** When a `body` exceeds ~40 lines, extract subviews or `@ViewBuilder` helpers. Don't pre-extract just because.
- **Previews** for new views, with environment objects stubbed. Don't ship a view without a working preview — they're the fastest UI development loop.
- **No business logic in `body`.** Compute derived state in the model, surface as a `@Published` property.

### Performance

SwiftUI recomputes `body` often and recreates views freely. Cheap bodies keep updates under the frame deadline ([Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)).

- **Never do expensive work in `body`, `init`, `onAppear`, or `onChange`.** Compute it asynchronously in the model, **cache the result**, and have `body` read the cached value.
- **Don't store view-builder closures.** A stored closure that captures `self` makes the view re-evaluate whenever *any* of its properties change. Call the closure in `init` and store its return value instead. This does *not* apply to action closures (`Button`, `onContinue`) or closures that take a parameter (`ForEach`) — leave those as-is.
- **Layout readers amplify updates.** `GeometryReader` / `ScrollViewReader` re-run their subtree on every parent layout change. Keep state that doesn't affect layout *outside* their subtree (we use `ScrollViewReader` in the chat views — watch this there).
- **The `@Observable` macro is off-limits.** It would replace `@Published`/`ObservableObject` and only fire on read properties, but it's macOS 14+ and we target **13.0**. Stay on `ObservableObject`; revisit only if the deployment target moves.
- **Profile, don't guess.** When a view feels slow, Product → Profile → the **SwiftUI** Instruments template surfaces long bodies and update-frequency hot spots before you start optimizing.

---

## Code hygiene

### Comments

**Don't write comments.** The strong default is zero. Code explains itself through good names, small functions, and clear types — if you reach for a comment to explain WHAT the code does, rewrite the code instead (rename the variable, extract the function, split the expression). A comment is a failure to make the code legible, not a feature.

This means a hard **NO** to:

- Narration that restates the next line (`// increment the counter`)
- Section headers / banners (`// MARK: -` dividers used as decoration, `// --- setup ---`)
- Task, fix, author, or caller references (`// added for issue #14`, `// TODO`, `// called from ContentView`) — the diff, PR, and issue tracker carry that
- Commented-out code — delete it; git remembers
- Docstrings on self-evident members

**The only exception** — and it is rare — is a non-obvious **WHY** that the code genuinely cannot express, where omitting it would lead the next reader to "fix" a deliberate choice and break something:

- A hidden external constraint ("Whisper hallucinates on silence — VAD threshold matters")
- A subtle invariant a future edit could violate ("must be called on `queue`")
- A workaround for a specific upstream bug ("AVAudioConverter caches identical inputs; don't rebuild")

If you're unsure whether a comment clears that bar, it doesn't — delete it.

### Naming

- Follow Swift API Design Guidelines (clarity at point of use, omit needless words, name based on roles).
- **Booleans read like predicates**: `isAuthorized`, `hasMicAccess`, `shouldShowPaywall`.
- **Methods read like commands or queries**: `startMeeting()`, `nextMeeting()`. Avoid `getXxx` — drop the `get`.
- **Properties never start with `_`** (Swift convention; `_underscore` is for compiler-generated symbols).
- **Acronyms**: `URL`, `JSON`, `ID` — uppercase. `userId`, `meetingURL`, `parseJSON`.

### Logging

- Always via `Log.<area>` (`Log.ui`, `Log.audio`, `Log.stt`, `Log.llm`). Never `print(...)`.
- Use `.info` for normal flow, `.error` for recoverable errors that the user might or might not see. Use `.debug` for chunk-level details that you wouldn't want spamming production logs.
- One line per event. Don't multi-line — they're harder to filter.
- Avoid logging user content (transcript text, summary text) at `info` level. `debug` is OK behind a flag.

### File organization

- Match the existing top-level folders (`Audio/`, `Auth/`, `Storage/`, `LLM/`, `Permissions/`, `Onboarding/`, `Language/`, `Backend/`, `Calendar/` — the last is being removed).
- A new feature gets its own folder. A new type for an existing feature goes in that folder.
- Don't introduce `Models/`, `ViewModels/`, `Helpers/`, `Utils/` — by-layer folders create artificial separation. Group by feature.

---

## Anti-patterns we avoid

| Don't | Why |
|---|---|
| Protocols with one conformer | Add when you have a real second use case (testing-with-mocks is a real use case, but only when you're actually mocking) |
| `Manager`, `Helper`, `Util`, `Service` everywhere | Suffix tells you nothing. If `XManager` is the only sensible name, the type probably owns too much |
| Hand-rolled threading primitives | Use actors / `@MainActor` / `nonisolated` / structured `Task` |
| Force unwraps in non-test code (`!`) | Use `guard let`, `if let`, or fail loud with `fatalError("message")` and document why crashing is correct here |
| Subclassing your own classes | Compose. We never subclass our own types — only Apple framework types where required (e.g. `NSPanel`) |
| `Codable` on types where only a subset gets serialized | Define an explicit `Codable`-conforming DTO. Don't bend the domain type to fit the wire format |
| Re-inventing UX (auth flows, settings panes, paywall mechanics) | Match what 3+ peer apps do. The user has been explicit about this — see memory `feedback-match-standard-ux` |
| Marketing language in `PLAN.md` or `README` | Documents reality, not aspiration. See memory `feedback-plan-matches-codebase` |

---

## When you're not sure

- **Read the most similar existing file** and match its shape. Consistency > local cleverness.
- **Ask the user** with a concrete, narrow question — not "what should I do here?" Show two options + your recommendation.
