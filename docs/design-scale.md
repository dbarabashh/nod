# Design scale

_Last updated: 2026-09-05_

The 4pt grid, the type roles and the layout widths — where they came from, what
was adopted, and what is still on the old ladder.

## Where it came from

A measurement pass over a peer desktop app (Granola), reverse-engineered from 16
screenshots at DPR 2 and normalised to CSS px. On macOS a CSS px and a point are
the same unit, so the numbers transfer directly.

What was adopted is the **system**: a 4pt base, a fixed set of steps, named type
roles with their leading, a content column that centres in the pane rather than
hanging off the sidebar.

What was **not** adopted:

- **Colour.** The palette is ours and stays ours — `DesignTokens.Palette` is
  untouched by this work.
- **The type face.** The source report rates its own confidence on font family
  as "low", and a display serif is a competitor's brand rather than a
  measurement. Every role is the system face. `Typography.display` is the slot
  to change if Nod ever takes a brand face of its own.

## What the app had before

Not a different scale — no scale. Counted across the view tree:

| | Values in use |
|---|---|
| `spacing:` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16 |
| `size:` | 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 14, 15 |
| Radii | 9, 12, 18 — one step on a 4pt grid, two off it |

`11.5` appeared 118 times and `12.5` 115, with nothing saying which meant "a row"
and which meant "a caption". That is drift, not design, and it is why two panels
that should match sit a point apart.

## The tokens

| Layer | Where | Notes |
|---|---|---|
| Spacing | `Theme.Space` | 4 / 8 / 12 / 16 / 24 / 32 / 40 / 48 |
| Type | `Theme.Typography` + `.textStyle(_:)` | role → size, weight and leading together |
| Layout | `Theme.Layout` | sidebar 188 (see below), content 488, editor 520 |
| Controls | `Theme.Control` | two heights (40 / 32), icon 16 / 12 |
| Radii | `Theme.Radii` | 8 / 12 / 16, plus a pill |

`NodTests/DesignScaleTests` pins what can actually break: every step on the
grid, no role at a half point, the 13pt floor for anything a person operates,
and — the one assertion that can fail for a reason outside the file — that the
declared leading still matches the shipped system face.

The migration itself is counted, not remembered. `.swiftlint.yml`'s
`hardcoded_type_size` custom rule flags `.system(size: <digit>)` anywhere
outside the theme, as a warning. **Baseline at the time of writing: 478.** That
number is the burndown; it is also what marks which convention a file follows,
so nobody has to remember.

### Leading

SwiftUI on macOS 13 can only *add* leading — there is no line-height API — so
`TextStyle.lineSpacing` is the difference between the role's line box and the
face's own, measured from `NSFont` rather than assumed. At the sizes in use:

| Role | Set as | SF's own | Added |
|---|---|---|---|
| `editor` | 15/22 | 18 | 4 |
| `ui` | 13/18 | 16 | 2 |
| `secondary` | 12/16 | 15 | 1 |
| `display` | 32 | 38 | — declares no line box, because SwiftUI cannot tighten to the 36 the source asks for |

## Where the report was not followed: the sidebar

The report measures 152. Nod's labels do not fit in it. Measured against the
system face at the primary role, with the sidebar's inset, the row's inset, a
16pt icon and its gap:

| Row | Needs |
|---|---|
| Give 50%, get a free month | 230 |
| Ambient context + "On" | 187 |
| Shared with me | 158 |
| Your account | 144 |
| New capture (pill) | 141 |

At 152 the capture pill wrapped to two lines and the whole footer ellipsized —
"Ambie…", "Give 50%, g…". The app the report measured navigates by "Home" and
"Notes"; this one navigates by phrases.

**188** is the smallest step on the grid that fits every row a person navigates
by, and leaves only the referral promo to truncate — a promo, not a
destination, and it already draws a tail. That is 44pt returned to the content
area against the old 232, which was itself fitted to the promo.

`NodTests/SidebarFitTests` holds this to the labels: every navigation label
fits, the ambient row fits with its status word, the capture pill sets on one
line, and one grid step narrower has to actually break something — otherwise
the width is not earned.

## Adoption

Done — the shared components, so the grid reaches every feature that draws
through them rather than through its own numbers:

- `SectionLabel` — both sizes now set at `micro`; the notch's difference is
  tracking and tint, not half a point
- `SecondaryPillButton` — padding was 11 and 10, now one step
- `SearchField` — four independent half-measures (12/11, 13/12, 8/7, 10/9)
  collapsed to one step between the two sizes
- `GlassPillButton` — fonts at 11.5/12/12.5/13 and vertical padding at 5/8/9,
  now two type roles and two paddings

**The shipped half is a visual change too**, and that is worth saying plainly:
`GlassPillButton`'s icons go 8/10/11 → a flat 12, its five sizes collapse to
three, the sidebar loses 44pt, Today's column loses 152, and the chat loses 260.
Every screen that draws a pill moves. None of it has been looked at in a running
window yet.

Not done — feature views still carry their own values (478 sites, counted by the
lint rule above). Migrating them is a pass per surface, and it is a visual
change on every screen, so it wants to be reviewed a surface at a time.

## Open questions before this stops being an experiment

- **The scale's values contradict the app's.** The primary role is 13pt; the
  four most-used sizes today are 11.5, 12.5, 12 and 11. So adopting a role is an
  enlargement, not a rename — the migration is a redesign wearing a refactor's
  clothes. Either re-anchor the roles to what the app ships, or accept the
  enlargement deliberately. The lint count makes the choice visible; it does not
  make it.

- The report's floor is 13pt for anything a person operates; the app's rows are
  at 11 and 11.5 today. `DesignScaleTests` asserts the floor for the *role*, but
  adopting it in the feature views makes the whole UI visibly larger. That is a
  product call, not a token one.
- The content column at 488 is narrower than what Today and the chat were drawn
  at (640 and 780). It is applied, and it wants a look on a real window before
  it is kept.
