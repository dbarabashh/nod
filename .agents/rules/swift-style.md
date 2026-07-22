---
description: Naming, error handling, and the anti-patterns we reject in Swift code.
globs: '*.swift'
alwaysApply: false
---

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): clarity at point of use, omit needless words, name by role. The rules below are where we deviate or the guidelines are silent.
- Never force-unwrap or force-cast in non-test code — SwiftLint fails the build on it. Use `guard let` / `if let`, or fail loud with `fatalError("why crashing is correct here")`.
- Name booleans as predicates (`isAuthorized`, `hasMicAccess`, `shouldShowPaywall`) and methods as commands or queries (`startMeeting()`, `nextMeeting()`). Drop `get` prefixes.
- Never prefix properties with `_`, and uppercase acronyms per Swift convention: `userId`, `meetingURL`, `parseJSON`.
- Prefer `throws` over `Result<T, E>` for async APIs — it matches the standard library.
- Conform error enums to `LocalizedError` only when the error is shown to the user (see `OpenRouterClient.ClientError`); otherwise a bare enum is enough.
- Catch at the boundary, not in the middle: repositories throw, view models catch and convert to a published error state.
- Don't swallow errors with `try?` unless you genuinely don't care — and then leave the one-line WHY.
- Surface network/Supabase errors as a retryable toast, never a crash. The "meeting save failed → retry?" flow is the template.
- Don't add a protocol with one conformer; wait for a real second use case (mocking counts only when you're actually mocking).
- Don't reach for `Manager`, `Helper`, `Util`, `Service` suffixes by default — if `XManager` is the only sensible name, the type probably owns too much.
- Don't bend a domain type to fit the wire format. Define an explicit `Codable` DTO when only a subset gets serialized.
- Don't leave an unowned `TODO`. Open an issue and link it, or finish the work.
- When unsure, read the most similar existing file and match its shape. Consistency beats local cleverness.
