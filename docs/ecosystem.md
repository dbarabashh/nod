# The Nod ecosystem — sibling repositories

All Nod repos live side by side under `~/dev/nod/`. They share **one Supabase
project** (prod ref `lptqvnizjwglilgeukwx`, sandbox branch
`zdpvmwqauczsfwlgflas`) and **one user account** — there is no second backend
anywhere in the ecosystem.

The workspace-level `~/dev/nod/AGENTS.md` carries the short version of this map
and is loaded automatically in every repo.

| Repo | What it is | Stack | Deploy |
|---|---|---|---|
| `Nod` (this repo) | macOS client — recording, transcription, summaries | Swift 5.9, SwiftUI, XcodeGen, macOS 13+ | GitHub Releases + Sparkle appcast |
| `nod-landing` | Marketing site `hellonod.app` — incl. rendered `/policies/*` and `/invite/:token` | Bun + React + Tailwind, custom `build.ts`, prerendered, i18n via `src/locales` | Vercel |
| `share-nod-ui-service` | Public share viewer — renders `/share/:token`, summary-only | React 19 + Vite 8 + shadcn/ui (`radix-nova`), pnpm | Vercel (`noindex`) |
| `nod-founder-dashboard` | Internal analytics for the two founders; reads **prod** Supabase via founder-gated `SECURITY DEFINER` RPCs, email-OTP auth | React + Vite, pnpm | Vercel |
| `nod-mobile` | iOS companion — voice notes + in-person capture, same account | SwiftUI, iOS 16+, plain Xcode project (no XcodeGen yet) | not shipped |

## Cross-repo rules

- **One backend, one schema.** Every schema change goes through migrations in
  **this repo's** `supabase/migrations/`, applied with the Supabase CLI. Never
  create a second Supabase project, never edit schema from the dashboard.
- **Design tokens flow desktop → web.** `share-nod-ui-service`'s "Midnight
  Eclipse" tokens in `src/index.css` are a 1:1 port of
  `Nod/Core/DesignSystem/Theme`. Keep names aligned so the two codebases stay
  cross-referenceable; when a desktop token changes, flag the web port.
- **Policy docs are authored here, rendered there.** `docs/policies/*.md` is the
  source; `nod-landing` publishes them at `hellonod.app/policies`. A policy edit
  here implies a landing-site update.
- **CSP on `hellonod.app` must allow Paddle** (`nod-landing/vercel.json`) or
  checkout dies with "Couldn't reach Paddle".
- **Sharing privacy invariants span three repos** — desktop mints the link
  (`MeetingStore.createShareURL` → `create_meeting_share`), the viewer renders
  summary-only (`get_shared_meeting`), and the `share-ask` edge function reads
  the transcript **server-side only**. The transcript must never reach a
  browser. Preserve this in every repo that touches sharing.
- **iOS is not a port.** The desktop's system-audio capture (`ScreenCaptureKit`),
  floating `NSPanel`, menu-bar item, and global hotkeys have **no iOS
  equivalent**. The mobile answer for those features is "not applicable", never
  a half-working stub. See `../nod-mobile/AGENTS.md`.
- **Port, don't rewrite.** Logic that already exists and is portable (LLM proxy
  client, stores, data models, recap parsing, dedup) moves over faithfully
  rather than being re-derived.
