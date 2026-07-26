# Policy documents ↔ code bindings

Public-facing policy drafts live in [`docs/policies/`](./policies/) — Security,
Privacy, Terms, Consent, Subprocessors, Refund, plus a `README.md` index. They
mirror what the marketing site at `hellonod.app/policies` ships (rendered by the
`nod-landing` repo).

Every claim is **tied to specific code in this repo**, so when you touch a piece
of code listed below, proactively flag that the matching policy needs updating —
even if the user didn't ask for the doc update. Bump the `_Last updated:_` line
whenever you edit a policy.

Current status (declared in every policy header): Nod is in **private beta**,
operated by **Dima Barabash as an individual developer** — no company is
incorporated yet, no SOC 2 process started, no per-jurisdiction governing-law
set. All contact emails resolve to `dbarabashdev@gmail.com`.

| What changed in code/infra | Update in `docs/policies/` |
|---|---|
| New/changed subprocessor (third-party API, OAuth provider, billing, analytics) | `subprocessors.md`, `privacy.md` § 3/5/6 |
| Audio is ever persisted (today: never; `WhisperTranscriber` discards chunks) | `security.md` "Audio recordings", `privacy.md` § 3.2 |
| OpenRouter privacy toggles flipped (ZDR off, "may train on request data" enabled, first-party endpoints re-enabled) | `security.md` § Model training, `privacy.md` § 4 |
| New table in `public.*` schema, or RLS dropped on any table | `security.md` "Infrastructure", `privacy.md` § 3 |
| SSL enforcement disabled (`supabase --experimental ssl-enforcement get`), TLS version downgraded | `security.md` "Trust at a glance" + "Infrastructure" |
| Soft-delete window changed from 30 days, or the `purge-trashed-meetings` pg_cron job removed | `security.md` "Access control", `privacy.md` § 7 |
| Backup retention changes (Supabase plan upgrade, PITR enabled) | `security.md` "Infrastructure", `privacy.md` § 7 |
| Analytics SDK added (PostHog, Sentry, Amplitude, etc.) | `privacy.md` § 3.8 "What we do not collect" (this list must stay accurate), `subprocessors.md` |
| New first-party telemetry event or table (e.g. `onboarding_events`) | `privacy.md` § 3.5 + § 3.8 — the "we do not track" list must stay true |
| OpenRouter key path changes (any client-side fallback, alternative proxy, new edge function) | `security.md` "Infrastructure" last bullet |
| Google OAuth scopes expanded beyond openid/email/profile (in `AuthService.signInWithGoogle`) | `privacy.md` § 3.1 |
| Consent disclaimer body changes (`ConsentStrings.swift`) | `consent.md`, `privacy.md` § 3.3; also bump `ConsentPreference.disclaimerVersion` |
| Screen reading widens: a new app in `ConferencingApp`, a new marker in `isMeetingWindowTitle`, reading outside a recording session, reading anything beyond the participant list, or persisting/transmitting what was read | `privacy.md` § 3.10 + § 3.8, `security.md` "Screen access" + "Trust at a glance", `consent.md`. Persisting or transmitting names would also need a **new** legal basis and a consent-script change |
| The pixel fallback widens (`ScreenTextRecognizer`): running before the accessibility read rather than after it, dropping the `recognitionInterval` floor, capturing anything but the frontmost cleared window, or retaining an image for any reason | `privacy.md` § 3.8 + § 3.10(b) table, `security.md` "Screen access" + "Trust at a glance". The load-bearing claim is that **no image is ever saved or transmitted** — the moment one is written to disk, cached, or uploaded, every one of those lines becomes false |
| A recording of the screen (video, or a stored screenshot) is ever added anywhere | `privacy.md` § 3.8, `security.md` "Trust at a glance" + FAQ, `consent.md` — and re-read whether this still fits the product's positioning at all |
| Meeting detection widens (`MeetingDetector`, `MeetingDetection.namesActiveCall`, a new `ConferencingApp` case): reading a window's *contents* rather than its title, reading apps outside `ConferencingApp`, storing or transmitting anything it saw, or starting a recording without the user clicking | `privacy.md` § 3.10(c) + § 3.8, `security.md` "Screen access" mode 3. The load-bearing claims are that it reads **titles only**, **stores nothing**, and **cannot start a recording on its own** — the last one breaks the moment anything reaches `beginRecording` without going through the panel's Start path |
| Meeting detection defaults change (`MeetingDetectionPreference`: off-by-default, sampling interval, the auto-finish countdown) | `privacy.md` § 3.10(c), `security.md` "Screen access" mode 3. Shipping it **on** is what the legitimate-interest basis rests on being narrow — widening what it reads while leaving it on by default needs the basis re-read |
| Exclusion controls change (`ScreenExclusions`, `WebsiteCategory`, `ScreenPrivacySection`) | `privacy.md` § 3.10, `security.md` "Screen access" — both promise the user can exclude apps, categories, and sites |
| Ambient context defaults change (`ScreenContextDefaults`: on-by-default, sampling interval, retention) or capture widens beyond the frontmost window | `privacy.md` § 3.10(b) table + § 7 retention row, `security.md` "Screen access" + "Trust at a glance". **Shipping it on by default would break the consent legal basis** (Art. 6(1)(a)) — it must stay opt-in |
| `screen_observations` schema changes, or its `pg_cron` purge is removed | `privacy.md` § 3.10(b) + § 7, `security.md` "What we do store". Retention is a stated promise enforced server-side, not a client convention |
| Sharing surface changes (`create_meeting_share` RPC, `share-ask` edge function) | `privacy.md` § 3 + the share viewer's privacy invariants in `../share-nod-ui-service` |
| Nod incorporates as a company | **every file** — replace "Dima Barabash, individual developer" with entity name + address, fill governing-law and supervisory-authority sections, bump "Last updated", give existing users 30-day notice |
| Paid tier launches (Paddle wired up) | `terms.md` § 7, `subprocessors.md` Paddle row moves out of "planned" |
