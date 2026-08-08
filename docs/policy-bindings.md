# Policy documents ↔ code bindings

Public-facing policy drafts live in [`docs/policies/`](./policies/) — Security,
Privacy, Terms, Consent, Cookies, Subprocessors, Refund, plus a `README.md` index. They
mirror what the marketing site at `hellonod.app/policies` ships (rendered by the
`nod-landing` repo).

Every claim is **tied to specific code in this repo**, so when you touch a piece
of code listed below, proactively flag that the matching policy needs updating —
even if the user didn't ask for the doc update. Bump the `_Last updated:_` line
whenever you edit a policy.

Current status (declared in every policy header): Nod is operated by **Dima
Barabash as an individual** — no company is incorporated yet, no SOC 2 process
started, no per-jurisdiction governing-law set. All contact emails resolve to
`dmytro@hellonod.app`.

| What changed in code/infra | Update in `docs/policies/` |
|---|---|
| New/changed subprocessor (third-party API, OAuth provider, billing, analytics) | `subprocessors.md`, `privacy.md` § 3/5/6 |
| Website consent, Google Tag Manager/Analytics/Ads, campaign storage, or browser-to-app attribution changes | `cookies.md`, `privacy.md` § 3.12/11, `subprocessors.md`, and the matching pages in `../nod-landing` |
| Connector OAuth scopes, token claims, grant revocation, MCP tools, or the user data returned by `supabase/functions/mcp` changes | `privacy.md` § 3.11/5, `security.md` "Official AI connectors" + "Access control", `subprocessors.md` "What we do not use", and the matching pages in `../nod-landing` |
| Audio is ever persisted (today: never; `WhisperTranscriber` discards chunks) | `security.md` "Audio recordings", `privacy.md` § 3.2 |
| OpenRouter privacy toggles flipped (ZDR off, "may train on request data" enabled, first-party endpoints re-enabled) | `security.md` § Model training, `privacy.md` § 4 |
| New table in `public.*` schema, or RLS dropped on any table | `security.md` "Infrastructure", `privacy.md` § 3 |
| Where the on-device speaker model comes from (`SpeakerDiarizer` / `PyannoteConfig` — today a first-use download from the public `argmaxinc/speakerkit-coreml` Hugging Face repo) | `security.md` "How Nod works", `privacy.md` § 5, `subprocessors.md` "What we do not use" |
| Diarization stops being on-device (any cloud diarization API) | `security.md` "How Nod works" + "Trust at a glance", `privacy.md` § 3.2/§ 5, `subprocessors.md` table — this would add a real subprocessor |
| SSL enforcement disabled (`supabase --experimental ssl-enforcement get`), TLS version downgraded | `security.md` "Trust at a glance" + "Infrastructure" |
| Soft-delete window changed from 30 days, or the `purge-trashed-meetings` pg_cron job removed | `security.md` "Access control", `privacy.md` § 7 |
| Backup retention changes (Supabase plan upgrade, PITR enabled) | `security.md` "Infrastructure", `privacy.md` § 7 |
| Analytics SDK added (PostHog, Sentry, Amplitude, etc.) | `privacy.md` § 3.8 "What we do not collect" (this list must stay accurate), `subprocessors.md` |
| New first-party telemetry event, property, retention rule, or table (`onboarding_events`, `product_events`, `share_product_events`) | `privacy.md` § 3.5/3.8/7, `security.md` "What we do store", `subprocessors.md`, `docs/app-store-privacy.md`, and the matching pages in `../nod-landing` |
| A new field on `profiles` (`WorkRole`, `AcquisitionSource`, anything asked in `ProfileStep`) | `privacy.md` § 3.2 — each field is its own row with its own purpose and legal basis, and a field collected for *us* (attribution, segmentation) is not the contract basis the assistant-context fields sit on |
| OpenRouter key path changes (any client-side fallback, alternative proxy, new edge function) | `security.md` "Infrastructure" last bullet |
| Google OAuth scopes expanded beyond openid/email/profile (in `AuthService.signInWithGoogle`) | `privacy.md` § 3.1 |
| Consent disclaimer body changes (`ConsentStrings.swift`) | `consent.md`, `privacy.md` § 3.3; also bump `ConsentPreference.disclaimerVersion` |
| Screen reading widens: a new app in `ConferencingApp`, a new marker in `isMeetingWindowTitle`, reading outside a recording session, reading anything beyond the participant list, or persisting/transmitting what was read | `privacy.md` § 3.10 + § 3.8, `security.md` "Screen access" + "Trust at a glance", `consent.md`. Persisting or transmitting names would also need a **new** legal basis and a consent-script change |
| The pixel fallback widens (`ScreenTextRecognizer`): running before the accessibility read rather than after it, dropping the `recognitionInterval` floor, capturing anything but the frontmost cleared window, or retaining an image for any reason | `privacy.md` § 3.8 + § 3.10(b) table, `security.md` "Screen access" + "Trust at a glance". The load-bearing claim is that **no image is ever saved or transmitted** — the moment one is written to disk, cached, or uploaded, every one of those lines becomes false |
| A recording of the screen (video, or a stored screenshot) is ever added anywhere | `privacy.md` § 3.8, `security.md` "Trust at a glance" + FAQ, `consent.md` — and re-read whether this still fits the product's positioning at all |
| Meeting detection widens (`MeetingDetector`, `MeetingDetection.namesActiveCall`, a new `ConferencingApp` case): reading a window's *contents* rather than its title, reading apps outside `ConferencingApp`, storing or transmitting anything it saw, or starting a recording without the user clicking | `privacy.md` § 3.10(c) + § 3.8, `security.md` "Screen access" mode 3. The load-bearing claims are that it reads **titles only**, **stores nothing**, and **cannot start a recording on its own** — the last one breaks the moment anything reaches `beginRecording` without going through the panel's Start path |
| Meeting detection defaults change (`MeetingDetectionPreference`: off-by-default, sampling interval, the auto-finish countdown) | `privacy.md` § 3.10(c), `security.md` "Screen access" mode 3. Shipping it **on** is what the legitimate-interest basis rests on being narrow — widening what it reads while leaving it on by default needs the basis re-read |
| Exclusion controls change (`ScreenExclusions`, `WebsiteCategory`, `ScreenPrivacySection`) | `privacy.md` § 3.10, `security.md` "Screen access" — both promise the user can exclude apps, categories, and sites |
| `defaultExcludedApps` or `defaultExcludedWebsites` shrinks, or the once-only offering breaks (a removed default comes back) | `privacy.md` § 3.10(b) "Excluded out of the box", which names the messengers, password managers and secret-sharing services by brand. Dropping one silently makes a published list false. Run `scripts/check-app-identifiers.sh` — a manager shipping under a second bundle id is uncovered without anything saying so |
| `ScreenExclusionRules.excludesWindow` precedence changes, or the always-include list gains power over an explicit exclusion | `privacy.md` § 3.10(b) "Always include". The load-bearing claim is that the allowlist overrides **only a category** — the moment it can re-open a site the user named, "an explicit exclusion always wins" is false |
| Ambient context defaults change (`ScreenContextDefaults`: on-by-default, sampling interval, retention) or capture widens beyond the frontmost window | `privacy.md` § 3.10(b) table + § 7 retention row, `security.md` "Screen access" + "Trust at a glance". **Shipping it on by default would break the consent legal basis** (Art. 6(1)(a)) — it must stay opt-in |
| The in-app ambient controls change (`AmbientContextMenu`, `ScreenContextService.pause`/`resume`/`deleteObservations`): a pause that no longer suppresses the write, a deletion window that doesn't match its label, or the off switch moving back out of reach | `privacy.md` § 3.10(b) table — the Turning it off / Pausing / Deletion rows each describe a control that exists in that menu. The load-bearing claims are that a pause **stops capture immediately and never outlives its deadline**, and that deletion is **immediate, permanent, and reachable in one click** |
| `screen_observations` schema changes, or its `pg_cron` purge is removed | `privacy.md` § 3.10(b) + § 7, `security.md` "What we do store". Retention is a stated promise enforced server-side, not a client convention |
| Sharing surface changes (`create_meeting_share` RPC, `share-ask` edge function) | `privacy.md` § 3 + the share viewer's privacy invariants in `../share-nod-ui-service` |
| Nod incorporates as a company | **every file** — replace "Dima Barabash, individual developer" with entity name + address, fill governing-law and supervisory-authority sections, bump "Last updated", give existing users 30-day notice |
| Paid tier launches (Paddle wired up) | `terms.md` § 7, `subprocessors.md` Paddle row moves out of "planned" |
| `plans.hours_are_unlimited` flips for any plan, or `plans.limits.hours_per_month` changes on a plan that claims unlimited | `terms.md` § 7 "Fair use on unlimited plans", and the pricing table in `../nod-landing` (12 locales). Pro is advertised as unlimited hours, so `hours_per_month` on Pro is the **fair-use threshold, never an allowance** — the published claims are that we don't meter, never bill overage, never cut off mid-meeting, and **email before acting**. Adding a hard stop, a throttle, or a charge at that ceiling makes all four false. Anything that renders the number to a Pro user (`PaywallView.statusSubline`, `features(for:)`) contradicts the page |
| Ambient context moves between plans (`Feature.ambientContext`, `plans.features`, the `screen_observations` insert/update policies) | `privacy.md` § 3.10(b) — the table describes a switch the user owns, and the plan can now suppress capture while that switch still reads "on". `terms.md` § 7 if it changes which plan includes it |
