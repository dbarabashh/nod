# Conventions

How we write Swift code in this repo. The defaults: **terse, conventional,
pragmatic.** Match Apple's [Swift API Design
Guidelines](https://www.swift.org/documentation/api-design-guidelines/) and
standard SwiftUI patterns; the rules below are where we deviate or where the
guidelines are silent.

The conventions themselves now live one rule per file in
[`.agents/rules/`](./.agents/rules/), so agents load only what a given file
needs. This page is the index.

| Rule | Applies to | Covers |
|---|---|---|
| [`comments.md`](./.agents/rules/comments.md) | always | Don't write comments; the rare non-obvious WHY exception |
| [`commits.md`](./.agents/rules/commits.md) | always | Lowercase, 4–5 words, no AI attribution trailer |
| [`swift-architecture.md`](./.agents/rules/swift-architecture.md) | `*.swift` | Layering, code placement, composition root, no singletons, no premature abstraction |
| [`swift-concurrency.md`](./.agents/rules/swift-concurrency.md) | `*.swift` | `@MainActor` defaults, structured concurrency, the real-time audio-thread constraint |
| [`swiftui.md`](./.agents/rules/swiftui.md) | `*.swift` | State-property choice, body performance, macOS 13 constraints |
| [`swift-style.md`](./.agents/rules/swift-style.md) | `*.swift` | Naming, error handling, anti-patterns, no force unwraps |
| [`design-system.md`](./.agents/rules/design-system.md) | `*.swift` | SF Symbols only, `Core/DesignSystem` reuse, standard macOS UX |
| [`logging.md`](./.agents/rules/logging.md) | `*.swift` | `Log.<area>`, never `print` |
| [`apple-apis.md`](./.agents/rules/apple-apis.md) | `*.swift` | Verify framework APIs via the sosumi MCP |
| [`xcode-project.md`](./.agents/rules/xcode-project.md) | `project.yml`, `*.pbxproj` | XcodeGen, tool-version pins, VAD vendoring |
| [`supabase.md`](./.agents/rules/supabase.md) | `supabase/**` | CLI + migrations only |
| [`policies.md`](./.agents/rules/policies.md) | `docs/policies/**` | Keeping public claims true |
| [`docs-reality.md`](./.agents/rules/docs-reality.md) | `README.md`, `docs/**` | Docs describe what the code does |

## Core philosophy

We optimize for **legibility a year from now** over cleverness today.

- **Don't over-engineer.** Three similar lines beats a premature abstraction.
- **Don't pre-validate impossible states.** Trust internal callers and framework
  guarantees; validate only at real boundaries.
- **No fallbacks for scenarios that can't happen.**
- **Half-finished is worse than not-started.** An unowned `TODO` rots — open an
  issue and link it.

## When you're not sure

- **Read the most similar existing file** and match its shape. Consistency beats
  local cleverness.
- **Ask with a concrete, narrow question** — not "what should I do here?" Show
  two options plus your recommendation.

Architecture background that isn't a rule (audio pipeline, panel flags,
permissions, entry flow) lives in [`docs/architecture.md`](./docs/architecture.md).
