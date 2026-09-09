---
description: UI conventions — Nucleo icon set, reuse DesignSystem components, match standard macOS patterns.
globs: '*.swift'
alwaysApply: true
---

- Use the Nucleo icon set for every icon in the UI, not SF Symbols. Icons are asset-catalog imagesets named `nc-<name>` (e.g. `nc-mic`, `nc-check`) in `Nod/Core/Resources/Assets.xcassets`, sourced from Nucleo "UI Essential" with the closest analog from another Nucleo set when UI Essential has a gap. Never use emoji as an icon.
- Reference an icon by its asset name: `Image("nc-mic")`, or `systemImage`/`systemName`-style parameters on custom components still hold an `"nc-…"` value, not a real SF Symbol. Add a new icon by creating its `.imageset` (SVG, `template-rendering-intent: template`, `preserves-vector-representation: true`) — never fall back to an SF Symbol because a Nucleo equivalent wasn't found.
- Author every icon SVG on the `viewBox="0 0 18 18"` grid, with stroke icons at an effective `stroke-width` of 1.5 on that grid. Never commit Nucleo's cropped-to-ink export (`viewBox="2.19 2.19 15.63 15.63"` and friends) — it makes the glyph a different size from its neighbours wherever the canvas is what gets drawn. `NodTests/GlyphIconInkTests` pins the glyphs that share a row.
- Build menu rows with `IconLabel`, never a bare `Image("nc-…")`. A SwiftUI frame does not reach an `NSMenu` row: AppKit draws `NSMenuItem.image` at the image's own size, so an unsized icon lands at its 18pt canvas next to 13pt text. `IconLabel` hands the menu an `NSImage` already cut to `size`; `NodTests/IconLabelSizingTests` pins that.
- Never hardcode `Color.white`, `Color.black`, or a literal hex in a view — reach for `Theme.Palette` (`overlay` for a translucent wash, `onAccent` for a label on an accent fill), and declare a new slot as a `Color.themed(light:dark:)` pair. A hardcoded white scrim is invisible on the Light theme and nothing in the code says so. `Color.white` is only correct on a saturated tint that is the same in both themes (`danger`, a label's own swatch).
- Check `docs/architecture.md` § Appearance and transparency before assuming a surface follows the theme — the notch, the menu-bar item, and the welcome screens (`WelcomeBackdrop`) each opt out for a different reason, and that list is the one place they're written down.
- Reuse `Nod/Core/DesignSystem/Components` and `Theme` before writing bespoke UI. New shared UI goes into `Core/DesignSystem/`, not into a feature folder.
- Match standard UX patterns for non-differentiating surface (auth, settings, paywall, onboarding): if 3+ peer macOS apps converge on a pattern, that's the pattern. Reserve design effort for actual product decisions.
- Never change `FloatingPanel`'s window flags casually (`.nonactivatingPanel | .borderless`, `.floating` level, `canJoinAllSpaces | stationary | fullScreenAuxiliary | ignoresCycle`) — they're the reason the panel survives Spaces switches and never steals focus. See `docs/architecture.md`.
- Keep every user-facing string language-aware: generated output follows `LanguagePreference` (`app.language`), which is an *output* preference and never a transcription constraint.
