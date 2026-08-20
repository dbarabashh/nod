---
name: swiftui-review
description: Use when building, changing, or reviewing Nod SwiftUI views, window behavior, or design-system integration.
---

# Review Nod SwiftUI work

1. Read `AGENTS.md` and the applicable Swift rules in `.agents/rules/`.
2. Inspect the existing primitives in `Nod/Core/DesignSystem/` before adding UI.
3. Verify unfamiliar Apple APIs with Sosumi when available, or official Apple documentation otherwise.
4. Preserve the macOS 13 target, activation-policy behavior, and non-activating panel constraints.
5. Run the narrowest relevant tests, then the project build when the change affects composition or window behavior.
