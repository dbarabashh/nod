# Architecture — the parts you can't infer from the file tree

## Source layout

Sources under `Nod/` are split by altitude into three top-level groups (the
placement rule lives in `.agents/rules/swift-architecture.md`):

- **`Nod/App/`** — composition root + window shell (`NodApp`, `AppServices`,
  `ContentView`, `FloatingPanel`, `StatusItemController`, `WindowCoordinator`).
- **`Nod/Features/<Name>/`** — one self-contained product surface per folder
  (`Auth`, `Meeting`, `History`, `Onboarding`, `Consent`, `Import`, `Export`,
  `Projects`, `Profile`, `Paywall`, `Settings`, `Update`, `Knowledge`, `Modes`).
- **`Nod/Core/`** — infrastructure shared across features: `Backend`,
  `Storage`, `LLM`, `Audio` (incl. the sherpa VAD wrapper +
  `Nod-Bridging-Header.h`), `Permissions`, `Hotkeys`, `Language`, `Log.swift`,
  plus `DesignSystem/` (`Components` + `Theme`) and `Resources/`
  (`Assets.xcassets` + `silero_vad.onnx`).

Dependency direction: `App/` and `Features/` use `Core/`; `Core/` must never
import a feature. XcodeGen scans `path: Nod` recursively, so the nesting is
organizational — but the bridging-header path in `project.yml`
(`SWIFT_OBJC_BRIDGING_HEADER`) is hardcoded, so update it if `Core/Audio/` ever
moves.

## Meeting-start lease

A recording is admitted once, by the server, before any audio exists:

1. `MeetingSession.requestRecordingStart()` mints the meeting's UUID and calls
   `meeting_start` on `llm-proxy`.
2. `start_meeting_lease` decides atomically under an advisory lock: it closes
   expired leases, takes over one that has gone 90 seconds without a heartbeat
   (a crashed or force-quit app), refuses a second concurrent recording, and then
   checks `resolve_entitlement(…)->can_start_meeting`.
3. Capture starts under the granted id. That id is the meeting id everywhere
   after: the WAL draft, every transcription chunk, and the persisted row.
4. Each `transcribe` call presents the id. The proxy strips it before the payload
   reaches a provider, and `validate_meeting_lease` doubles as the heartbeat —
   writing at most once a minute, not once per chunk.
5. At End the lease is detached, the final flush completes, and only then is
   `meeting_end` sent. A lost `meeting_end` costs minutes, not hours: the TTL is
   15 minutes and renewed only by use.

Two consequences worth keeping: the allowance can only ever refuse a **new**
meeting, and a lease refusal is HTTP **423** — never 409, which the client maps to
the single-device lock and treats as a forced sign-out.

## Entry flow

Nod launches as an accessory (`LSUIElement = YES`), then switches
`NSApp.setActivationPolicy(.regular)` at runtime (`WindowCoordinator`) to show
a Dock icon and a normal window when one is visible or while sharing the panel;
it drops back to `.accessory` otherwise.

`NodApp` is a near-empty SwiftUI `App`; the real bootstrap is in
`AppDelegate.applicationDidFinishLaunching` (`Nod/App/NodApp.swift`). It
constructs every service exactly once, wires them together, then either shows
the onboarding window or the floating panel based on
`OnboardingState.isCompleted`. Services are passed downstream via
`@EnvironmentObject`.

## Audio pipeline (the hot path)

The data flow that produces a transcript:

1. **`AudioCaptureService`** captures two independent streams simultaneously:
   microphone (`AVAudioEngine` with `installTap`) and system audio (`SCStream`
   via `ScreenCaptureKit`). Both are required for a dialogue transcript. Mic
   device can be overridden via `preferredInputUID` (persisted to UserDefaults).
   System audio capture needs Screen Recording TCC permission — that's why the
   app prompts for it despite "only" wanting audio.
2. **`TranscriptStore`** owns two `WhisperTranscriber` instances tagged `.me`
   and `.them`, and forks the mic / system buffers into them respectively.
   Emits `TranscriptEntry`s for live UI.
3. **`WhisperTranscriber`** normalizes incoming buffers to 16 kHz mono Float32
   via a cached `AVAudioConverter` and feeds them to an on-device **Silero VAD**
   (sherpa-onnx, `SherpaVAD.swift`). The VAD detects whole speech segments —
   start at speech onset, end after a natural pause — so each chunk is a
   complete utterance cut on a real silence, never mid-word. Each emitted
   segment is POSTed as a 16-bit PCM WAV through
   `OpenRouterClient.transcribe(...)` and surfaces as one `TranscriptEntry`.
   Segmentation is owned by the VAD config in `makeVAD()`: `minSilenceDuration`
   (the pause that closes a segment), `minSpeechDuration` (drops sub-blips like
   "um"), and `maxSpeechDuration` (a safety cap so a non-stop talker still
   streams and chunks stay within Whisper's window). The VAD also subsumes the
   old "skip silence so Whisper doesn't hallucinate 'Thanks for watching!'"
   gate — it simply emits no segment for silence.
4. Transcription requests intentionally omit a fixed `language` and `prompt` so
   Whisper can auto-detect mixed-language speech within a meeting without being
   nudged toward a prior chunk's language or wording. The language picker
   controls generated output (summary, title, chat default) and the meeting's
   stored language code, not a hard STT lock.

## Floating-panel UX

`FloatingPanel` (an `NSPanel` subclass) uses `.nonactivatingPanel | .borderless`,
`.floating` window level, `canJoinAllSpaces | stationary | fullScreenAuxiliary |
ignoresCycle` collection behavior. This is what makes the panel survive Spaces
switches, stay above other windows, and never steal focus. Don't change these
flags casually — they're the whole reason the panel UX feels right. The primary
UI is this floating non-activating panel, anchored to the left of the screen.

## Permissions

`PermissionManager` handles mic + screen recording. Notable patterns:

- Screen Recording's TCC API doesn't distinguish `notDetermined` from `denied`,
  so `PermissionManager` synthesizes the distinction with a persisted "we've
  prompted before" flag (`permissions.screenRecording.prompted`).
- The manager listens to `NSApplication.didBecomeActiveNotification` and
  re-checks status — this auto-refreshes the UI when the user returns from
  System Settings.
- Deep links to the correct Settings pane via
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  (and `Privacy_Microphone`).
- After granting Screen Recording, `ScreenCaptureKit` won't pick up the new TCC
  entry until the app process restarts. The onboarding flow exposes a "Quit &
  Relaunch" button for this — see issue
  [#3](https://github.com/dbarabashh/Nod/issues/3).

Two sources can say a meeting is happening — `MeetingDetector` (a call is
running on this Mac) and `ScheduledMeetingWatcher` (the calendar says one is
starting, on a 20-second timer). Neither raises an offer. Both publish a
*candidate*, and **`MeetingOffers` is the only thing that asks the user**: it
owns the sound, the 45-second expiry, accept/decline/mute, and the memory of
what has been answered.

That memory is a **quiet period, not a key**. The two sources cannot share an
identity — the calendar knows `title@start`, the detector a bundle id, and
neither can compute the other's — so once a meeting is answered nothing asks
again until it would be over (the invitation's `endsAt`, or a flat ten minutes
when only the Mac told us). Without it, declining the calendar's card at 13:59
and opening the call at 14:01 produced a second offer, with a second sound, as
if the first had never happened.

The calendar's candidate wins wherever both exist, and a richer one arriving
mid-offer upgrades the card in place **without sounding again** — it is the same
question, better answered.

`ScheduledMeetingWatcher`'s timer is owned by the Settings switch —
`CalendarService.isEnabled` starts and stops it — because `privacy.md` § 3.11
promises the timer stops, not merely that the query is skipped.

Calendar (EventKit) is deliberately **outside** `PermissionManager`, in
`CalendarService`: mic and Screen Recording are what the product needs to work
at all and are asked for in onboarding, while calendar access is optional and
opt-in from Settings → General. `CalendarService` carries its own switch alongside the grant, because
a TCC grant can't be handed back from inside the app. `requestFullAccessToEvents`
is macOS 14+; the 13.0 path uses `requestAccess(to:)`. Both
`NSCalendarsUsageDescription` and `NSCalendarsFullAccessUsageDescription` must
stay in `project.yml` — each OS reads a different one, and a missing key crashes
at the prompt — **and** `com.apple.security.personal-information.calendars` must
stay in `Nod/Nod.entitlements`: the hardened runtime requires it even though Nod
is unsandboxed, and without it `tccd` silently refuses to show the prompt at all.
See `docs/build-setup.md` § "Adding a macOS permission".

## Language model

`LanguagePreference` is a user-facing output-language preference, not a
transcription constraint. Keep `WhisperTranscriber` auto/multilingual so
recruiter-style flows work: a Portuguese interview can include an English
assessment block, the transcript preserves the English, and the LLM can later
evaluate the candidate's English from the original passages.

## Configuration

- **Supabase**: production project ref `lptqvnizjwglilgeukwx` (eu-west-1),
  linked via `supabase/config.toml`. The client URL + key live in
  `Nod/Core/Backend/SupabaseConfig.swift`, **switched by build config** — Debug
  points at the `develop` sandbox branch, Release at production (see
  `docs/supabase.md`). Server-side secrets (incl. `OPENROUTER_API_KEY`) are set
  via `supabase secrets set` — never in the bundle.
- **LLM / Whisper config**: server-side, in the `llm-proxy` Edge Function
  (`supabase/functions/llm-proxy/`). The client only knows the proxy URL + the
  user's Supabase JWT; provider routing and the OpenRouter API key live
  server-side. Chat and Whisper *model* overrides can still be set per-device
  via `openrouter.model` / `whisper.model` UserDefaults keys — they're forwarded
  through the proxy in the request payload.
- **User preferences** (persisted in `UserDefaults` under `com.example.nod`):
  - `app.language` — preferred generated-output language for titles, summaries,
    chat, and meeting metadata (e.g. `"uk"`). Transcription itself stays
    auto/multilingual and preserves the language actually spoken. Set via the
    in-app picker; the `defaults write` route is for testing only.
  - `audio.input.deviceUID` — preferred microphone device, set in Settings →
    General → Microphone, or from the chevron on the meeting bar's mic control
    (whose other half mutes). Unset means "follow the system default", which the
    service keeps following live.

## In-flight changes the code doesn't yet reflect

- **LLM proxy migration (#11)** — `OpenRouterClient` historically called
  OpenRouter directly with a client-side key (`UserDefaults:
  openrouter.apiKey`). The target is the Supabase Edge Function
  (`supabase/functions/llm-proxy/`) that takes a Supabase JWT, forwards to
  OpenRouter server-side, and enforces per-`user_id` quota at the proxy.
- **Calendar removal (#8)** — `Nod/Calendar/UpcomingMeetingService.swift`
  (EventKit-based) and all its wiring in `NodApp` + `ContentView` are scheduled
  for deletion. Don't add features on top of it.
- **Multilingual expansion (#12)** — `LanguagePreference` now covers the
  supported output languages, while STT runs auto/multilingual so code-switched
  speech is preserved in the transcript.
- **Meeting persistence (#14)** — meetings are stored in a Supabase `meetings`
  table from day 1 (no local JSON), with soft delete + 30-day trash (#16).

## Official AI connectors

The remote MCP endpoint is `supabase/functions/mcp`. Its universal `/mcp`
route accepts only Supabase OAuth access tokens with the exact environment
resource URI as `aud`, `nod_permissions: ["meetings:read"]`, a `client_id`, and
the database role `mcp_connector`. OAuth remains disabled by default through
both Supabase configuration and `MCP_OAUTH_ENABLED`; production can therefore
deploy the code before the public listing is enabled.

`mcp_connector` has no direct table, sequence, or function privileges. The Edge
Function verifies the token with Supabase Auth, then reads with service
credentials while applying the authenticated `user_id` to every meeting and
transcript query. This is the boundary that prevents a connector token from
using PostgREST or reading another account.

The server uses the official Model Context Protocol TypeScript SDK and MCP Apps
extension. It exposes read-only `search`, `fetch`, `list_meetings`, and
`get_transcript` tools plus the `ui://nod/meeting-browser.html` app resource.
Clients without MCP Apps render the text fallback. Transcript pages contain 100
segments by default, accept at most 250, stop at 100,000 characters, and return
`nextCursor` when more content remains.

Legacy `nod_pat_` credentials continue through `/mcp/<token>` and `connect`
during the migration window. Those responses carry deprecation, sunset, and
migration-link headers; after `LEGACY_MCP_PAT_DISABLE_AFTER`, they return
`410 Gone`. New PAT issuance stops only when `official_connectors_enabled` is
set in `app_config`, so disabling that flag restores the rollback path.
