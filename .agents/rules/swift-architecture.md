---
description: Where new Swift code goes, how services are composed, and the layering rules.
globs: '*.swift'
alwaysApply: false
---

- Place new code by altitude: shared by 2+ features and screen-agnostic → `Nod/Core/`; a self-contained product slice → `Nod/Features/<Name>/`; app bootstrap or window plumbing → `Nod/App/`.
- Dependencies point one way: `App/` and `Features/` may use `Core/`; **`Core/` must never import or reach into a feature.**
- Instantiate long-lived services only in `AppDelegate.applicationDidFinishLaunching` (`Nod/App/NodApp.swift`), and pass them downstream via `@EnvironmentObject`. Never add `static let shared` singletons — explicit dependencies keep tests and previews swappable.
- Respect the four layers: Views render state and dispatch intents (no business logic, no networking); Stores/Services own state and side effects; Repositories do Supabase/PostgREST access with no UI concerns; value types are `struct` + `Codable`.
- Default to value types. Reach for `class` only for identity, reference semantics, or `ObservableObject` — and then make it `final`.
- Never subclass our own types. Compose instead; subclassing is only for Apple framework types that require it (e.g. `NSPanel`).
- Don't fragment files by type — one file may hold closely related types (`TranscriptEntry` + `TranscriptStore`).
- Don't create `Models/`, `ViewModels/`, `Helpers/`, `Utils/` folders. Group by feature inside `Features/`, by capability inside `Core/`.
- Don't over-engineer: a protocol, factory, generic, or wrapper needs ≥2 real callers before it exists. Three similar lines beats a premature abstraction.
- Don't pre-validate impossible states or add fallbacks for scenarios that can't happen. Validate only at real boundaries: user input, network responses, untyped third-party SDK output.
- `Core/Audio/` holds the bridging header; `project.yml`'s `SWIFT_OBJC_BRIDGING_HEADER` path is hardcoded, so update it if that folder ever moves.
- Full map of the runtime architecture (audio pipeline, panel, permissions): `docs/architecture.md`.
