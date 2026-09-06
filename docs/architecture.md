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
constructs every service exactly once, wires them together, then
`WindowCoordinator.reconcile()` picks the surface from `OnboardingState`:
the onboarding window for `.welcome` and `.profile`, the notch running its
setup cards (`NotchSetupStage`: permissions, ambient context, calendar) once
the flow has handed off to `.notch`, and the notch alone once `isCompleted`.
The setup skips any ask this Mac has already answered and ends on the last
card's button — or on any card's own close, which completes the flow and
leaves the rest to Settings. Services are
passed downstream via `@EnvironmentObject`.

The Ask hotkey (`HotkeyAction.askNod`, ⌘⇧K by default) lands in the notch too:
idle, it opens `NotchAskCard` over the shared `KnowledgeChatStore` thread and
makes the panel key so the field takes the caret without a click; during a
recording it expands the meeting bar's own Ask box instead. There is no
separate quick panel any more.

## Onboarding narration

Each onboarding step says a short, pre-written line aloud once, on arrival
(`Nod/Features/Onboarding/OnboardingNarration.swift`) — the window's two
steps through a dedicated `AppServices.onboardingNarrator: SpokenAnswer`
(the notch doesn't exist yet), the notch's own setup cards through
`NotchModel.voice`, the same instance the ask feature speaks answers with.
Both go through `SpokenAnswer.sayScripted(_:language:)`, a `purpose:
"narration"` line that the proxy still routes through the OpenRouter rewrite
step before TTS — the copy itself is final and never generated, but reading
it in spoken register (contractions, natural pacing) instead of verbatim is
what keeps it sounding like the same voice as an answer. `NotchSetupContent`
gates re-narration to an actual stage change via `.id(stage)`, so an
unrelated `NotchModel` republish while on the same card doesn't say the line
again.

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
   complete utterance cut on a real silence, never mid-word. Silero only calls a
   frame speech once its probability crosses the threshold, a window or two after
   the word began, so `PreRollWindow` re-attaches the 0.25 s before the onset to
   each segment's audio (matching `minSilenceDuration`, the most that can be
   prepended without reaching into the previous utterance). Without it the
   decoder guesses the attack it never heard — "там на проді все ок" came back as
   "там напродів совок". The lead-in goes to the model only: timestamps still
   mark the speech onset, and diarization still clusters on the speech alone.
   Each emitted segment is POSTed as a 16-bit PCM WAV through
   `OpenRouterClient.transcribe(...)` and surfaces as one `TranscriptEntry`.
   Segmentation is owned by the VAD config in `makeVAD()`: `minSilenceDuration`
   (the pause that closes a segment), `minSpeechDuration` (drops sub-blips like
   "um"), and `maxSpeechDuration` (a safety cap so a non-stop talker still
   streams and chunks stay within Whisper's window). The VAD also subsumes the
   old "skip silence so Whisper doesn't hallucinate 'Thanks for watching!'"
   gate — it simply emits no segment for silence.
4. Transcription requests intentionally omit a fixed `language` so the model can
   follow mixed-language speech without being nudged toward a prior chunk's
   language. The language picker controls generated output (summary, title, chat
   default) and the meeting's stored language code, not a hard STT lock.
5. The STT model is `openai/gpt-4o-transcribe`, not Whisper. Whisper conditions
   its decoder on one language token per segment, so it renders a whole chunk in
   the single language it picked and translates the rest — a Ukrainian sentence
   carrying English loanwords comes back wholly one or wholly the other, never as
   spoken. `gpt-4o-transcribe` has no such token and keeps code-switching intact.
   Whisper is a `whisper.model` override away, and everything Whisper-only
   degrades rather than breaks: `verbose_json` (hence per-segment metrics and the
   detected language) is Whisper-only, so `HallucinationFilter` falls back to its
   text heuristics and diarization keeps span-level accuracy without
   sentence-level splits. The rolling `prompt` tail is still sent but OpenRouter
   ignores it; only the direct-Groq path ever applied it.

### A live conversation, tapped open

A bare tap on `HotkeyAction.holdToAsk` (⌘T, held under `HeldQuestionRecorder
.minSeconds` — a real hold is the section below) opens a continuous voice
session instead of one clip: `RealtimeVoiceSession` mints a short-lived
credential from the proxy (`kind: "realtime_token"`, `_shared/realtime.ts`) —
model `gpt-realtime-2`, voice, and a friend persona all baked in server-side —
then holds its own `URLSessionWebSocketTask` straight to
`wss://api.openai.com/v1/realtime`, no proxy in the loop for the rest of the
call. The mic streams out continuously as 24 kHz mono PCM16
(`input_audio_buffer.append`); the server's own VAD (`turn_detection:
server_vad`) decides when the person has stopped talking and starts
answering; the reply streams back as `response.output_audio.delta` chunks,
played through an `AVAudioPlayerNode` as they arrive, with transcript deltas
debounced (~60 ms) into the pill's `.speaking(words)` state. Talking over the
assistant triggers the server's own barge-in (`interrupt_response: true`);
since that guarantee is WebRTC/SIP-only, the client also flushes its own
queued playback on `input_audio_buffer.speech_started` so nothing already
scheduled talks over the interruption.

The model has exactly one tool, `ask_nod(question)` — a live conversation
knows nothing about the account on its own, and everything it can answer
about sessions, calendar, tasks, projects or beats goes through this one
call into `AppServices.voiceChat`, a `KnowledgeChatStore` instance dedicated
to voice and capped at five turns (`maxTurns`, `KnowledgeChatStore
.turnsToDrop`) — its own thread, never the Library's, so a live follow-up
resolves against what was just said without either polluting the Library's
history or growing without bound. Because that memory lives on `AppServices`
rather than inside the session, an accidentally-ended or dropped connection
does not lose it — the next tap starts a fresh socket with the same last few
exchanges still behind it.

Tapping again, clicking the pill, or Escape ends the session
(`RealtimeVoiceSession.stop()`); so does 15 minutes of continuous connection
(`maxSessionSeconds`) or the socket failing — everything upstream of an
already-connected session bounds only how long the *token* is valid to
start one, never how long the conversation itself may run, so this client
timer is the only cap on that. `RealtimeVoiceSession.isActive` excludes
`.failed`: a failure tears the session down immediately and shows the reason
for a moment, but the very next tap starts clean rather than being read as
"end a session that no longer exists." A hold while a session is open does
nothing until release (which just ends it) — the key's only job once a
conversation is open is to close it.

### A question spoken into the notch

Holding `HotkeyAction.holdToAsk` (⌘T by default) opens the microphone for as
long as the key is down. With no meeting running the surface stays at rest:
`NotchPresentation.voice(VoiceAskPhase)` is the pill saying "Listening…" then
"Thinking…", and the Ask card opens (`revealAsk(baseline:)`) only once the
answer exists. The pill's width is measured from its label
(`VoiceAskPhase.restingSideWidth`) — a word wider than its half would be drawn
under the hardware rather than truncated. During a meeting the bar's own Ask
box shows the same phases.
The resolver puts the pill above rooms, offers and cards — the person is
mid-sentence to Nod. `HotkeyManager` reports Carbon's `kEventHotKeyReleased`
alongside the press so the notch knows when it is let go.
`HeldQuestionRecorder` assembles one 16 kHz mono clip on its own queue. With
no recording running it opens a private `AVAudioEngine`; during one it calls
`AudioCaptureService.divertMicrophone(to:)`, which routes the tap's buffers to
the clip instead of `onMicBuffer`, so the question never lands in the
transcript. The diversion only happens while a microphone tap is live
(`isCapturingMicrophone`); a media session or a paused recording gets Nod's
own engine. A hold ends itself at sixty seconds (`voiceHoldLimit`), since
Carbon reports no release for a binding torn down mid-hold, and `start`/`stop`
on the capture service clear any diversion left behind. On release the clip
goes to the proxy's `dictate` kind — the `transcribe` path minus the meeting
lease, refused unless it is WAV and at most sixty seconds by its own header
(`_shared/dictation.ts`) — and the text is submitted exactly as a typed
question would be (`submitIdleAsk` / `submitAsk`, with `spoken: true`). What
goes wrong is said on the row for a moment (`VoiceAskPhase.failed`).
`SpokenAnswer` is one mouth: every line passes through one queue and one
player, so nothing is said over anything else. The moment the question is
transcribed it queues an acknowledgement; when the answer lands it queues the
answer. Each line goes to the proxy's `speak` kind with a `purpose` and the
question, which the proxy turns into audio in two steps: `completeOnce`
(`_shared/complete.ts`) asks `openai/gpt-4o-mini` through OpenRouter — the
same route as chat — to *write* the line, given a persona (`_shared/speech.ts`
`PERSONA`: a friend who sat in on the day, warm and on their side, never a
customer-service voice), the language (Whisper's detection of the question,
else the app language) and a length rule — one short sentence for a quick
question, two or three with details only for a meeting, a session, a day's
work or a brief. That line, and only that line, then goes straight to
OpenAI's own `/v1/audio/speech` (`gpt-4o-mini-tts`, voice `SPEECH_VOICE` —
`cedar` by default, the warmer of OpenAI's two newest and the male one) with
an `instructions` string describing the performance (unhurried and settled
for the answer, a quick aside for the acknowledgement) — the one control a
chat-completions voice doesn't expose, and the reason this one call goes to
OpenAI directly instead of through OpenRouter. It never reads the card's text.
The proxy refuses a line over 1,500 characters, a language outside
`AppLanguage`, and more than 40 calls per user per ten minutes; each call
lands in `usage_events` as `kind = 'speak'` with an estimated cost. Without
both keys it answers 422 (not retried) and the line is read by
`AVSpeechSynthesizer` in the language's best installed voice. A short, flat
answer (`looksAlreadySpoken` — no markdown, no URL/path/identifier, under
220 characters) skips the script-writing hop entirely and goes straight to
TTS, since a quick fact needs no rephrasing; the `instructions` string is
otherwise one shared "voice identity" for both the acknowledgement and the
answer (same warmth, pacing character, and steady volume), with only the
energy differing, so the two lines read as one continuous person rather than
two takes. The per-user rate limit is only refunded on a network-level
failure (unreachable, timeout) — never on a non-2xx from either provider,
since the caller's own content can provoke that and refunding it would
reopen the meter to the abuse it exists to stop. While a line
plays the phase is `.speaking(words)`: the card shows the words with "Esc to
stop", the resting pill says "Speaking…" if the card was closed; Escape — or a
click on the pill, which has no key window for Escape to reach — cuts it off,
and so does the next hold. The question's own phase and the words being said
are kept apart (`voicePhase` vs `speakingWords`, merged for display by
`syncVoiceDisplay`) so "Thinking…" holds while the acknowledgement plays under
it; a tool approval asked for mid-answer reveals the card at once.
`config.excludesCurrentProcessAudio` keeps that voice out of the system-audio
stream, but a Mac on speakers will still hear it through the microphone like
any other sound in the room.

## Floating-panel UX

`FloatingPanel` (an `NSPanel` subclass) uses `.nonactivatingPanel | .borderless`,
`.floating` window level, `canJoinAllSpaces | stationary | fullScreenAuxiliary |
ignoresCycle` collection behavior. This is what makes the panel survive Spaces
switches, stay above other windows, and never steal focus. Don't change these
flags casually — they're the whole reason the panel UX feels right. The primary
UI is this floating non-activating panel, anchored to the left of the screen.

## Appearance and transparency

`AppearancePreference` (`Features/Settings/`) owns the theme; the two defaults
keys live in `AppearanceDefaults` (`Core/DesignSystem/Theme/`), because the
surfaces that read the transparency switch are `Core` components and `Core` may
not import a feature:

- **Theme** — `system` (default), `light`, `dark`. Applied once to
  `NSApp.appearance` from `AppDelegate.applicationDidFinishLaunching` and again
  on every change; every window Nod opens inherits it. `WindowCoordinator`
  deliberately does not set a per-window appearance.
- **Transparent background** — off by default. Every translucent surface goes
  through `BackdropSurface`, which owns the one gate: the key read through
  `@AppStorage` (an injected object cannot reach four separate hosting roots)
  plus macOS's own Reduce transparency
  (`@Environment(\.accessibilityReduceTransparency)`), which overrides it. That
  covers the behind-window blur (`WindowBackdrop`, `PanelMaterial`) and the
  in-window `Material` fills (`Shape.glassFill()`); the Settings row disables
  itself when macOS has already forced the answer.

Themed colours are plain `static let`s: `Color.themed(light:dark:)` (and
`NSColor.themed` for the AppKit-drawn surfaces) wraps an `NSColor` dynamic
provider, so every `Theme.Palette.…` call site follows the appearance it is
drawn in without knowing a theme exists. `Theme.Palette.overlay` is the base
for every translucent scrim — white on dark, black on light. A SwiftLint
`custom_rules` entry (`hardcoded_color`) fails a bare `Color.white` / `.black` /
inline hex outside the token files and the three opt-out surfaces below, so a
wash cannot be hardcoded again.

Three surfaces deliberately do **not** follow the setting, each for its own
reason — this is the whole list:

- **The capture surface.** `NotchPanel` pins `NSAppearance(named: .vibrantDark)`,
  `NotchStateContent` pins the matching SwiftUI `colorScheme`, and `NotchView`
  fills with black. It hangs off the cut-out and has to read as part of the
  machine. Both pins are required — tokens read the scheme, `NSVisualEffectView`
  reads the window.
- **The menu-bar item.** `StatusItemController` draws into the system menu bar,
  which follows the Mac and not `NSApp.appearance`, so it resolves
  `NSColor.labelColor` against the status button's own `effectiveAppearance`.
- **The welcome screens** (`SignInView`, `OnboardingView`). `WelcomeBackdrop`
  paints `Theme.Gradients.welcome` — hellonod.app's hero blue, ported stop for
  stop from the site's `HeroBackdrop` — and pins `colorScheme` to `.dark`
  alongside it. The ground is a saturated blue in every theme, so the content on
  it is white in every theme, and the white pills keep their dark labels.

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
- **Live-room approval (unreleased, sandbox only)** — `join_live_room` now
  returns `status`, and a join the server cannot prove from the caller's own
  synced calendar lands as `pending` until the host approves it. `find_live_room`
  returns a null `host_name` to a caller it cannot place in the meeting.

  A build that predates the change reads a `pending` row as an ordinary join —
  the listener watches a bar whose transcript never fills, and the host, whose
  `room_listeners_of` now answers only for `joined`, never sees a request. Both
  failures are silent. No shipped client is affected (`main` carries no
  live-room code and the released build is 69), but the gate below makes that
  hold however the feature is rolled out.

  **`app_config.live_room_required_build` gates both ends.** It ships at
  `2147483647` — no build qualifies — so the live room is **off in every
  environment**, including after a merge to prod, until somebody turns it on.
  `find_live_room` and `join_live_room` answer nothing when either the caller's
  or the host's `profiles.app_build` is below it, so an old client is never
  offered the room rather than being refused halfway through one. Leaving,
  approving and denying stay open at any build, so nobody is trapped in a room.

  Turn it on per branch, never in a migration (`.agents/rules/supabase.md`):

  ```sql
  select public.activate_live_room(<build that ships the approval UI>);
  ```

  Service-role only and monotonic — it refuses to lower an active gate.

  **Deploy order:** migrations first is safe (the feature stays off), then the
  client, then `activate_live_room` with that client's build. Rolling the
  migrations back is safe too: `JoinedRoom.status` is optional and an absent
  field reads as the old `joined` behaviour. Tracked as NOD-118.

  A team share is separately still reachable by an administrator who invites an
  account into the team (NOD-117); the policy pages say so until it is fixed.

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

The consent screen is ours, not Supabase's: Supabase's OAuth 2.1 server hands
the request to `nod-landing/src/pages/oauth-consent.tsx`, which signs the user in
and then approves or denies the authorization. Google is the only sign-in method
it offers publicly. Loading it with `?review=1` also reveals an email-and-password
form, which exists so app-store reviewers can sign in without a Google account or
a second factor; only accounts seeded with a password through the Auth admin API
can use it, and email signup stays disabled so no one can create one.

The server uses the official Model Context Protocol TypeScript SDK and MCP Apps
extension. It exposes read-only `search`, `fetch`, `list_meetings`, and
`get_transcript` tools plus the `ui://nod/meeting-browser.html` app resource.
Clients without MCP Apps render the text fallback. Transcript pages contain 100
segments by default, accept at most 250, stop at 100,000 characters, and return
`nextCursor` when more content remains.

The private founder analytics MCP is a separate Edge Function at
`supabase/functions/founder-mcp/`, proxied through the founder dashboard's
`/mcp` route. It is private, unpublished, and connected only through ChatGPT
Developer Mode; it never adds analytics tools to the customer meeting MCP.
Access requires the independent `founder_analytics:read` permission, the exact
founder resource audience, an enabled database gate, and an exact user UUID plus
per-connection DCR client ID binding in `private.founder_mcp_client_access`.
The Edge Function has a second kill switch and rejects invalid or deleted
bindings before MCP server initialization, so ineligible users cannot discover
the tool catalog.

The founder function uses the caller's OAuth token and sends every tool call
through one bounded, rate-limited, read-only database gateway. The
`mcp_connector` role retains no table access and cannot execute the underlying
report functions. Signup lists are pseudonymous unless identity is explicitly
requested. Revoked attribution is never reconstructed; legacy acquisition rows
without durable visitor or consent evidence return `unknown` with no source
fields. The dashboard reads per-user source through the bounded
`founder_user_attribution(p_user_ids uuid[])` RPC for the current page only.
Nod does not persist MCP responses or identity-search text. Content-free
audit metadata records actor, client, tool, status, identity inclusion, query
length, and returned row count for 90 days. Retention by a founder's connected
ChatGPT account is outside Nod's server-side control.

Legacy `nod_pat_` credentials continue through `/mcp/<token>` and `connect`
during the migration window. Those responses carry deprecation, sunset, and
migration-link headers; after `LEGACY_MCP_PAT_DISABLE_AFTER`, they return
`410 Gone`. New PAT issuance stops only when `official_connectors_enabled` is
set in `app_config`, so disabling that flag restores the rollback path.
