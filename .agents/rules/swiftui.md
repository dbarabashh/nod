---
description: SwiftUI state-property choices, view size, and body performance.
globs: '*.swift'
alwaysApply: false
---

- Pick the state property by ownership: `@StateObject` when the view *creates* the object, `@ObservedObject` when it *receives* it, `@EnvironmentObject` when it's injected up the tree. `@State` for view-local value types, `@Binding` to hand write access to a child. Mixing these up causes update bugs that take hours to find.
- Never do expensive work in `body`, `init`, `onAppear`, or `onChange`. Compute asynchronously in the model, cache the result, and have `body` read the cached value.
- Never store view-builder closures — a stored closure capturing `self` re-evaluates the view whenever *any* property changes. Call it in `init` and store the returned view. This does not apply to action closures (`Button`, `onContinue`) or parameterized closures (`ForEach`).
- Keep state that doesn't affect layout outside `GeometryReader` / `ScrollViewReader` subtrees — layout readers re-run their whole subtree on every parent layout change (watch this in the chat views).
- Never use the `@Observable` macro — it's macOS 14+ and we target 13.0. Stay on `ObservableObject` / `@Published`.
- Keep no business logic in `body`. Compute derived state in the model and expose it as a `@Published` property.
- Extract subviews or `@ViewBuilder` helpers once a `body` exceeds ~40 lines — but don't pre-extract.
- Ship a working preview with every new view, with environment objects stubbed.
- Profile before optimizing: Product → Profile → the **SwiftUI** Instruments template shows long bodies and update hot spots.
