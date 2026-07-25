---
description: UI conventions — SF Symbols only, reuse DesignSystem components, match standard macOS patterns.
globs: '*.swift'
alwaysApply: true
---

- Use SF Symbols for every icon in the UI. Never use emoji as an icon — extend the component with a `systemImage` parameter instead of embedding a glyph in a string.
- Reuse `Nod/Core/DesignSystem/Components` and `Theme` before writing bespoke UI. New shared UI goes into `Core/DesignSystem/`, not into a feature folder.
- Match standard UX patterns for non-differentiating surface (auth, settings, paywall, onboarding): if 3+ peer macOS apps converge on a pattern, that's the pattern. Reserve design effort for actual product decisions.
- Never change `FloatingPanel`'s window flags casually (`.nonactivatingPanel | .borderless`, `.floating` level, `canJoinAllSpaces | stationary | fullScreenAuxiliary | ignoresCycle`) — they're the reason the panel survives Spaces switches and never steals focus. See `docs/architecture.md`.
- Keep every user-facing string language-aware: generated output follows `LanguagePreference` (`app.language`), which is an *output* preference and never a transcription constraint.
