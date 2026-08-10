# Privacy Policy

_Last updated: 2026-08-08_

> This policy describes the data practices that already exist in the
> product today — every claim is tied to code you can inspect.

This Privacy Policy describes how Nod ("Nod", "we", "us", "I") collects, uses,
stores, and shares personal data when you use the Nod macOS application
and the related services hosted at `hellonod.app`. It applies to all users,
worldwide.

If you have questions about this policy or your data, contact
**dmytro@hellonod.app**.

---

## 1. Who we are (data controller)

Nod is operated by **Dima Barabash**. There is no incorporated company
behind Nod — that's an honest disclosure, not a gap we're hiding.

For the purposes of the EU/UK GDPR, the data controller is Dima Barabash
personally. The contact point is **dmytro@hellonod.app**.

Paid subscriptions are sold through **Paddle.com Market Limited**, which
acts as our Merchant of Record. Paddle is an independent controller of the
billing and tax data it collects to process your payment — see Paddle's own
privacy notice for how it handles that data. Nod never receives or stores
your full card details.

## 2. What Nod is

Nod is a macOS app that records meetings playing through your Mac's
speakers and microphone, transcribes them via Whisper, and produces an
AI-generated summary using a large language model. It lives in the notch at the
top of your screen and never records without you pressing record.

The data flow is summarised in our [Security page](./security.md) and the
list of third parties in our [Subprocessors list](./subprocessors.md).

---

## 3. What we collect, why, and the legal basis

### 3.1 Account data

| Data                                  | Why we need it                         | Legal basis (GDPR Art. 6) |
|---------------------------------------|----------------------------------------|---------------------------|
| Your email address                    | To identify your account and contact you about service issues | Contract (Art. 6(1)(b)) |
| Google OAuth identifier and OpenID profile claims (name, picture) | To authenticate you when you sign in with Google | Contract (Art. 6(1)(b)) |

We use Google OAuth via Supabase Auth. We do **not** request any Google
scopes beyond OpenID, email, and basic profile — we do not read your Gmail,
Calendar, Drive, or contacts.

### 3.2 Meeting content

| Data                                   | Why we need it                                   | Legal basis |
|----------------------------------------|--------------------------------------------------|-------------|
| Meeting **transcripts** (per-chunk text, with speaker side and timestamp) | To show you what was said and feed it to the summariser | Contract (Art. 6(1)(b)) |
| Meeting **summaries** (AI-generated text) | The core feature — that's what you're using Nod for | Contract (Art. 6(1)(b)) |
| Meeting metadata (start/end time, title, language, source platform: macOS / iOS, session **kind**: meeting / voice note / media) | To list and organise your sessions and understand which client created them | Contract (Art. 6(1)(b)) |
| Transcript **embeddings** (vector + chunk text, in `session_embeddings`) | To let you ask questions across your past sessions ("Ask Nod") | Contract (Art. 6(1)(b)) |
| **Chat messages** with the per-session assistant (`chat_messages`) | To answer your questions about a session and keep the thread | Contract (Art. 6(1)(b)) |
| **Cross-session chats** (`knowledge_threads`, `knowledge_messages`) — your questions, the answers, and the sessions/excerpts each answer used | To let you reopen and continue an "Ask Nod" conversation instead of losing it on quit | Contract (Art. 6(1)(b)) |
| **Source clicks** (`retrieval_feedback`) — the question asked, the session opened from the answer, and its position in the list | To improve which sessions search returns for a question | Legitimate interest (Art. 6(1)(f)): improving the product you're using, on your own content |
| **Entities** (people / projects / topics extracted from a session) | To link related sessions and power scoped search | Contract (Art. 6(1)(b)) |
| Your optional **profile** (name, what you want Nod to focus on) | To give the assistant context about you | Contract (Art. 6(1)(b)); you may leave it blank or clear it anytime |
| Your optional **role** (founder, recruiter, sales, …), asked once during setup | To pick a sensible default meeting mode for you, and to understand who Nod is for. It is **not** sent to the assistant | Legitimate interest (Art. 6(1)(f)): setting the product up for you and knowing who uses it; you may leave it blank |
| Your optional answer to **"how did you hear about us?"** | To know which channels bring people to Nod, so we know where to spend | Legitimate interest (Art. 6(1)(f)): running the business; you may leave it blank |

While a meeting is recording, Nod also reads the **last few minutes of the
transcript as the meeting goes**, through the same EU proxy and the same
subprocessors as the summary, to spot what the room commits to, decides, or
leaves open. It runs only after enough new speech has landed and at most once a
minute, so silence and a paused recording send nothing. Nothing extra is stored:
what it finds is held in memory for the length of the meeting and saved with the
session's action items at the end. No new recipient sees your transcript because
of this — it is the same summarising model, asked earlier and more often.

The embeddings, chat messages, and entities are derived from transcript
content you already chose to record; they are stored in the same
Supabase database, in the same `eu-west-1` region, under the same per-user
Row-Level Security. Cross-session "Ask Nod" conversations are saved as threads
you can reopen — and delete, which removes their messages with them.

We do **not** store raw audio. Audio exists only as transient memory inside
the app and inside the Whisper request, for the duration of a single
~5-second chunk. The bytes are released as soon as the transcript returns.
There is no audio file, no waveform export, no cloud-stored recording.

### 3.3 Consent acknowledgement audit log

When you click "Acknowledge & Start" on the recording disclaimer, we write
a row in `consent_acknowledgements` containing your user ID, the timestamp,
the disclaimer version you saw, its language code, and the app version that
wrote the row. This is a durable audit trail in case a meeting participant
later disputes consent.

Legal basis: legitimate interest in maintaining a legal-defence record
(Art. 6(1)(f)), balanced by the fact that the row contains no meeting
content.

### 3.4 Usage metadata

For each call to our LLM proxy we record, in `usage_events`: the model
used, prompt/completion token counts (for chat) or audio duration (for
transcription), the OpenRouter generation ID, the HTTP status, and the
upstream cost in USD. We do **not** record the prompt content or the
response content in this table.

We use this to enforce per-account quotas, choose pricing, and detect
abuse.

Legal basis: legitimate interest in operating a sustainable service
(Art. 6(1)(f)).

### 3.5 Product interaction and onboarding progress

Nod records a minimal first-party event log in `onboarding_events` and
`product_events`. It covers setup steps, app opens, capture requests and
outcomes, summary/transcript/action-item views, Ask completion, copy/export,
paywall views, and successful checkout creation. Each row contains a random
event ID, timestamp, app-session or capture ID where relevant, platform, app
version, event name, and bounded categories such as session kind, entry point,
stage, failure reason, surface, content type, AI feature, outcome, plan, and
billing cycle.

The event log never contains meeting titles, transcript or summary text,
questions, answers, arbitrary error messages, email, clipboard contents, share
tokens, or other free-form app content. Completed meetings, persisted chats,
action items, shares, and payments are measured from their domain records
rather than trusting a client event.

On iOS, the first onboarding screen offers **Allow** and **Don't Allow** before
any event is sent. Earlier setup impressions remain on the device until Allow;
Don't Allow discards them and sends nothing. A random installation ID lets an
allowed pre-sign-in setup journey be claimed by the account after sign-in.
Unclaimed rows are deleted after 30 days. The choice can be withdrawn in iOS
Settings, which clears queued events and stops future product telemetry.

All app events go only to Nod's Supabase database in `eu-west-1`; neither app
contains a third-party analytics SDK, and app activity is not sent to Google.
Authenticated product events are deleted with the account.

Legal basis on macOS: legitimate interest in diagnosing reliability and
improving product usability (Art. 6(1)(f)). Legal basis on iOS: consent
(Art. 6(1)(a)); withholding or withdrawing it does not affect product access.

### 3.6 Device binding

To enforce your plan's device limit — and prevent one login from being shared
across many machines — we store one row per signed-in device in `user_devices`:
a stable per-machine identifier derived from your Mac's hardware UUID, your
computer's name, the platform (`macos`), and the timestamps the device was
first bound and last seen. How many devices you can use at once follows your
plan (Trial and Starter 1, Pro up to 3).

The hardware identifier is read on-device via Apple's IOKit and is used **only**
for this access control. It is not an advertising identifier, is not shared with
any third party, and is not used to profile you or track you across apps or the
web.

Legal basis: legitimate interest in securing accounts and preventing
unauthorised credential sharing (Art. 6(1)(f)).

### 3.7 Subscription and billing state

When you start a trial or buy a plan, we store one row per account in
`subscriptions` describing the state of your subscription — never your card
details (those stay with Paddle). The row holds your plan tier, its status
(trialing / active / past_due / canceled), the current billing period
start/end, your trial end date, and the Paddle **customer** and
**subscription** identifiers we use to reconcile webhooks and open the Paddle
customer portal for you.

| Data | Why we need it | Legal basis |
|------|----------------|-------------|
| Plan, status, billing-period dates, trial end date (`subscriptions`) | To grant the features and limits you paid for and know when access lapses | Contract (Art. 6(1)(b)) |
| Paddle customer ID and subscription ID (`subscriptions`) | To match Paddle's billing events to your account and open your billing portal | Contract (Art. 6(1)(b)) |

The plan catalogue itself (`plans`, `plan_prices`) holds no personal data —
it lists the tiers and prices everyone sees. Every `subscriptions` row is
protected by the same per-user Row-Level Security as the rest of your data,
in the same `eu-west-1` region.

### 3.8 What we do **not** collect

- The macOS app embeds **no** analytics SDKs (PostHog, Mixpanel, Amplitude,
  Segment, Google Analytics, Sentry, etc.). The only in-app product telemetry
  is first-party operational and funnel data stored in our own database. The
  marketing website analytics described in § 3.13 is optional and stays off
  until you consent.
- We do **not** collect arbitrary screen names, dwell time, typed questions,
  answers, errors, titles, clipboard contents, or meeting content in product
  telemetry. Only the bounded events and categories in § 3.5 are accepted.
- We do **not** send meeting content, transcript text, account email, name, or
  Supabase user ID to website analytics or Google Ads.
- We do **not** connect to Google, Microsoft, or any other account to read your
  email, calendar, or files. Nod can read the calendar **already set up on your
  own Mac** — on the device, and only if you switch it on (§ 3.11). That is a
  macOS permission, not a connected account, and nothing read from it is stored
  or sent anywhere.
- We do **not** collect your contacts or address book.
- We do **not** record video of your screen, and we do **not** save an image
  of it — ever. What Nod keeps from your screen is always **text**. With
  ambient context on, a window whose text macOS cannot describe is read from
  its pixels in memory and discarded in the same moment; only the recognised
  text is stored (§ 3.10).
- We do **not** log your keystrokes, read your clipboard, or capture password
  fields.
- We do **not** read anything from an app, category, or site you have
  excluded — the check runs before anything is read.
- We do **not** keep a screen index at all unless you switch **ambient
  context** on yourself (§ 3.10). It is off by default and never enabled by an
  update.
- We do **not** sell your personal data to anyone, ever.

### 3.9 Importing from other apps (Granola)

If you previously used **Granola**, Nod can import your past meetings'
**transcripts** from Granola's own offline cache file on your Mac
(`~/Library/Application Support/Granola/cache-v3.json`). This runs **only**
when you explicitly tap **Import from Granola** in Settings.

- It reads a **local file only** — no Granola account, password, or API call
  is involved, and Nod never sends anything **to** Granola. The import works
  fully offline.
- Only transcript text, the speaker side (`me` / `them`, derived from
  Granola's microphone-vs-system channel), and per-line timestamps are
  imported. Granola's AI notes and summaries are **not** imported.
- Imported meetings are stored exactly like meetings you record yourself
  (`meetings` / `meeting_transcripts`, same `eu-west-1` region, same per-user
  Row-Level Security) and you can delete them the same way.

Legal basis: Contract (Art. 6(1)(b)) — you asked us to bring your own data
into Nod.

### 3.10 What Nod reads from your screen

Nod reads from the screen in three separate ways. All three keep **text, never
an image**, and they work primarily through the macOS accessibility interface —
the same one screen readers use. **No video is recorded and no image of your
screen is ever saved, in any of them.** (a) and (b) require the macOS
**Accessibility** permission, which you grant explicitly; (c) reads only a
window's title, through the same **Screen Recording** permission you already
granted so Nod can hear a meeting.

One exception, in ambient context only, is described in (b): some apps
(Slack, Figma and other Electron or canvas-drawn apps) tell macOS almost
nothing about what they are showing. For those, Nod reads the window's pixels
in memory and converts them to text on your Mac. The image is never written to
disk, never uploaded, and is released as soon as the text is extracted.

**(a) Call participants — while a session records.** To label who said what,
Nod needs to know how many people are on the call, so it reads the
**participant list** of a running conferencing app.

- It reads **text, not pixels.** Nod uses the macOS accessibility interface,
  the same one screen readers use, to read the labels a window already
  exposes. It takes **no screenshots** and records **no video** of your
  screen.
- It looks only at **running conferencing apps** (Zoom, Teams, Webex, Slack),
  asking them in turn and stopping at the first one that names anyone — a call
  in a browser was otherwise shadowed by whichever conferencing app happened to
  be open alongside it. For a **browser**, it reads only a window whose title
  names a call (for example "Meet – abc-defg-hij"); every other window and tab
  is skipped without being read. Discord is never read at all: its windows are
  DMs and server channels, not a participant list.
- It runs **only while a recording is running**, and re-reads the list about
  every 15 seconds for as long as it lasts. Reading it once at the start missed
  everyone who had not joined yet, and the participant *count* is what makes
  speaker separation accurate, so the readings are merged as the call goes on.
  It never runs when nothing is being recorded.
- Nod uses the **number** of participants for on-device speaker clustering,
  and the **names** to put a name to a voice in your summary. The name list is
  sent once, with the transcript, to the summarising model through our EU proxy
  under Zero Data Retention — the same path and the same protections as the
  transcript itself (§ 4, § 5). It is **not stored** as its own record: the
  list is dropped when the session ends, and only whatever the summary itself
  says is kept.
- The model is instructed to leave a speaker unnamed when the transcript does
  not make the match unambiguous — the summary then reports what was said with
  no name attached to it, and the transcript keeps showing that voice as
  "Speaker 2". A wrong name is worse than an unnamed speaker.
- Without the Accessibility permission this step is skipped, and Nod falls
  back to guessing the number of speakers from the audio alone.

**(b) Ambient context — only if you switch it on.**

Nod can keep a time-limited index of text from the window you are working in,
so you can ask it about what you were doing and not only about what was said
out loud. This reads beyond a meeting, so it carries the tightest controls in
the product:

| | |
|---|---|
| **Default** | **Off.** You switch it on yourself — in Settings → Privacy, or from the **Ambient context** control at the bottom of Nod's sidebar, which states the same thing this row does before it turns anything on. It is never switched on by an app update. |
| **Turning it off** | The same sidebar control switches it off in one click, and always shows whether it is on, off, or paused. You never have to go looking for the off switch. |
| **Pausing** | You can pause capture for 15 minutes, an hour, or the rest of the day without switching the feature off. Nothing is read while it is paused, and it resumes on its own when the time is up. A pause survives quitting Nod, and never outlives its own deadline. |
| **What is stored** | The window's text, the app's identifier, the window title, and a timestamp, in `screen_observations`. No images, no keystrokes, no clipboard, no password-field contents. |
| **How often** | About every 5 seconds, and only for the window you are actually looking at — the focused one, never the app's other windows. An unchanged screen stays a **single row**, not one per sample; its timestamp is refreshed at most once a minute, so Nod can tell how long a window was up without storing it again. |
| **How it reads** | The accessibility interface first. When a window tells macOS almost nothing — Slack, Figma and other Electron or canvas-drawn apps — Nod converts that window's pixels to text **on your Mac**, at most once every 20 seconds, and only for a window the accessibility read came up short on. This needs the **Screen Recording** permission you already granted for meeting audio; without it, the step is skipped. It also needs macOS 14 or later. |
| **What happens to the image** | Nothing is saved. It exists in memory for the moment recognition takes, is never written to disk and never uploaded, and is released immediately. Only the recognised text is stored. |
| **How long** | Every row carries an expiry — 14 days by default, and you choose. A scheduled job deletes expired rows server-side, so the index shrinks on its own even if you never open Nod again. |
| **Exclusions** | Your blocklist is checked **before** anything is read — including before any pixel is read. An excluded app or window is never traversed and never recognised. |
| **Excluded out of the box** | Two groups are on the blocklist before you touch it. **Personal messengers** — WhatsApp, Telegram, Messages, Messenger, Signal, Viber, Discord — so a private conversation is never the first thing captured. **Password managers and one-time-secret services** — 1Password, Bitwarden, LastPass, Dashlane, Keeper, NordPass, Proton Pass, Enpass, KeePassXC, Apple Passwords, and the matching websites plus pwpush, One-Time Secret, Privnote, Yopass, scrt.link and 1ty.me — because a vault window lists every account you own, and a one-time secret exists to be read once and destroyed. All of them are ordinary entries you can remove in Settings → Privacy if you want that app or site read; removing one is remembered and it is not added back. |
| **Always include** | Category exclusions match keywords in a window title, so they are broad and will sometimes catch a site you want read — a supplier portal under "Shopping", a recruiting call under "Social media". You can list those sites as always-included, and they are captured despite the category. This cannot re-open a site you excluded by name: an explicit exclusion always wins. |
| **Deletion** | Yours to delete at any time, from the same sidebar control: the last 5 minutes, the last 15 minutes, the last hour, or everything Nod has ever read from your screen. Deletion is immediate and permanent, and it does not touch your sessions or transcripts. What it does not do is stop capture: if ambient context is still on and you are still looking at the same window, that window will be read again as a new observation — pause or switch it off first. Account deletion removes all of it. |

Legal basis: Consent (Art. 6(1)(a)) — this one is opt-in, and you can
withdraw it by switching it off, which stops capture immediately; existing
rows expire or can be deleted at once.

We would rather state the trade than bury it: with ambient context on, Nod
holds a time-limited record of text you had on screen. That is more than a
meeting recorder holds. It is off unless you choose otherwise, it is bounded,
and it is yours to delete.

**(c) Meeting detection — noticing that a call has started.**

So that you don't have to remember to press record, Nod can notice when a video
call begins and offer to record it. It never starts on its own: the offer is a
card you click, and clicking it takes you through the same consent and language
steps as pressing Start yourself.

- **What it reads.** Which apps are running, **which** app is using your
  microphone (macOS names the app; Nod never hears what it is recording), and
  the **window titles** of conferencing apps only — never the contents of any
  window, in any app. It does not use the accessibility
  interface at all; window titles come from the same **Screen Recording**
  permission Nod already needs to hear a meeting.
- **What it stores.** Nothing. A title is matched in memory and dropped when the
  offer goes away. There is no row, no file, and nothing leaves your Mac.
- **What it is matched against.** The call-marker words above, and — on your Mac
  only — the titles of sessions you have already recorded, so the offer can tell
  you that you have had this conversation before and how much of it is still
  open. That comparison runs entirely on your device, against sessions Nod has
  already loaded: nothing is sent anywhere, no search is run on our servers, and
  no model ever sees the title.
- **Which apps.** Zoom, Microsoft Teams, Webex, Slack and Discord, plus a
  browser window whose title names a call (for example "Meet – abc-defg-hij").
  Windows belonging to any other app are not looked at.
- **How often.** Every few seconds while no recording is running, and while one
  is, to notice that the call has ended.
- **When the call ends.** If Nod is recording a Zoom call, it wraps up and
  summarises about half a minute after Zoom's meeting process exits — with the
  panel raised, a visible countdown, and a button to keep recording; anyone
  still speaking cancels it. This exists so a meeting you forgot to stop doesn't
  become forty minutes of an empty room. A window title is never used to end a
  recording: it disappears when you switch tab or Space, not only when the call
  is over.
- **Off in one click.** Settings → General turns detection off entirely, and
  the card itself offers "Never for <app>" for a single app. An app on your
  screen-reading blocklist is never detected either.

Legal basis: Legitimate interest (Art. 6(1)(f)) — offering to record the
meeting you are in is the product's core purpose, and it is served by reading a
window title and nothing more. You can switch it off at any time.

- You can exclude any app, whole categories of website, or specific sites in
  **Settings → Privacy**, and the exclusions apply to **all three** modes above.

Legal basis for (a): Legitimate interest (Art. 6(1)(f)) — attributing speech to
speakers is the feature you are using Nod for. Participants' names are read
locally, used transiently, and travel no further than the summarising model
already handling the transcript of the same conversation.

### 3.11 Your calendar — only if you switch it on

A window title is a poor way to tell *which* meeting is starting: Microsoft
Teams names it, Zoom usually says only "Zoom Meeting", and Google Meet often
shows nothing but a room code. Your calendar names it every time. With this on,
the offer to record can tell you that you have had the same meeting before and
how much of it is still open, instead of just that a call is happening.

| | |
|---|---|
| **Default** | **Off.** You switch it on yourself in Settings → General, and macOS then asks you separately. It is never switched on by an app update. |
| **What it is not** | **Not a connected account.** There is no Google or Microsoft sign-in, no OAuth, no token, and no calendar API. Nod reads the calendar database already on your Mac — the same one the Calendar app shows you — through the macOS **Calendars** permission, exactly like the microphone permission you already granted. |
| **When it reads** | On a timer while the switch is on — about every 20 seconds — so Nod can tell you a meeting is starting before you have opened anything. It also reads when a call is detected, and once more when a recording finishes: an invitation is often written minutes *after* the call started, so that last read is what finds it. The timer stops the moment you switch the feature off. |
| **What it reads** | Events around the moment it asks — the title, the start and end times, whether you declined it, whether the entry contains a video-call link, and **who was invited**: each person's name (or, where the invitation carries no name, their address), and which of them is you. Rooms and equipment are skipped, as is anyone who declined. Nothing else about the event is looked at. |
| **What it stores** | The **names of the people invited** go into the recording's own summary, the same way the participant list read from a conferencing app already does (§ 3.10(a)) — so a summary can say "Alina" instead of "Speaker 2". Nothing else is kept: the title is compared against your existing sessions on your Mac and dropped, and no separate record of the event or its invitees is ever written. |
| **Why the names** | To count how many people other than you should be heard in the recording, which is what makes speaker separation accurate, to put a name to a voice, and to tell you who a meeting that is starting is with. This replaces reading the conferencing app's window for the same thing — the calendar is both more accurate and far less intrusive, since it needs no access to what is on your screen. |
| **What it does with a meeting that is starting** | Shows you a card, with a sound. That is all it does: the card has a button, and recording begins only when you press it — the same rule as a detected call (§ 3.10(c)). Nod never starts a recording because a calendar said so. |
| **Writing** | Never. Nod does not create, change, or delete anything in your calendar. |
| **Turning it off** | The same switch in Settings → General. Nod stops reading immediately, whether or not macOS still shows the permission as granted — and you can revoke the permission itself in System Settings → Privacy & Security → Calendars. |

Legal basis: Consent (Art. 6(1)(a)) — this one is opt-in, and you withdraw it by
switching it off, which stops the reading immediately. Nothing was retained to
delete.

### 3.12 Official ChatGPT and Claude connectors

You can authorize a supported AI client to read your Nod meetings. The consent
screen identifies the client, redirect address, and single read-only permission
before anything is shared. The connector can return meeting titles, dates,
summaries, and transcript text for your account; it cannot create, edit, or
delete Nod data. Transcript access is paginated and bounded.

Supabase Auth stores the OAuth grant and rotating refresh-token state. Access
tokens are bound to Nod's exact MCP resource and carry only
`meetings:read`. The connector's database role has no direct table access;
server-side queries are filtered by the authenticated user ID. You can list and
revoke grants at `/oauth/authorized-apps`, after which refresh and reconnect
require authorization again.

Legal basis: Contract (Art. 6(1)(b)) — this processing occurs only when you ask
Nod to connect your account to a client and approve the displayed access.

### 3.13 Website analytics and acquisition attribution

The marketing website offers optional analytics so we can understand which
pages and campaigns lead to a download, trial, first completed session, and
paid subscription. All analytics and advertising storage is denied by default.
Google Tag Manager, Google Analytics 4, Google Ads measurement, and Vercel Web
Analytics load only after you choose **Allow analytics**. You can decline or
withdraw that choice at any time from **Privacy settings** in the site footer.

When enabled, the website records random first-party visitor and browser-session IDs, the
sanitised page path, event name, broad CTA placement, external referrer host,
UTM campaign parameters, Google click identifiers when present, and the Google
Analytics client ID. Invite tokens, OAuth data, checkout transaction query
parameters, meeting content, and account identity are excluded. Sensitive
routes do not load Google or Vercel analytics.

If you begin Google sign-in from the macOS app, the default browser briefly
opens a Nod page. With analytics consent, that page links the browser visitor
ID to a random, 24-hour sign-in relay. After authentication, Nod claims the
relay and stores the selected first and last campaign touches against your Nod
account. This lets us count trials, first completed sessions within seven days,
and paid conversions by campaign. Server-side Google Analytics events use only
the consented Analytics client ID and event details; they do not contain your
Nod user ID, email, or name.

Legal basis: Consent (Art. 6(1)(a)). Withholding or withdrawing consent does not
affect the website, sign-in, download, trial, or paid service. Attribution will
then be incomplete, which we report as coverage rather than guessing.

---

## 4. Model training

**We do not train any machine-learning model on your data.** We have also
configured our subprocessors so that they do not use your data for
training:

- Speech-to-text runs primarily on **Groq**, whose Services Agreement
  prohibits using inputs or outputs to train any model and which retains
  no customer data by default (only transient error/abuse logs, ≤ 30 days).
- LLM and fallback Whisper calls go through OpenRouter with Zero Data
  Retention enabled for non-frontier models and the "may train on request
  data" routes (both paid and free) explicitly disabled.
- First-party endpoints for OpenAI, Anthropic, and Google are disabled in
  our OpenRouter account. Traffic is routed to enterprise endpoints
  (Azure OpenAI, AWS Bedrock, Google Vertex AI), which contractually do
  not train on customer data.

See [Security § Model training](./security.md#model-training) for the
exact OpenRouter configuration.

---

## 5. Who we share data with

We share data only with subprocessors who help us operate Nod. The full
list, including what data each receives and where they are located, is in
our [Subprocessors page](./subprocessors.md).

We do **not** sell or rent personal data to anyone. We share data with
third parties only when one of the following applies:

- It's a subprocessor on the published list, acting under a data
  processing agreement (Supabase, Groq for speech-to-text, OpenRouter,
  Anthropic via AWS Bedrock / Google Vertex for LLM summaries and chat,
  OpenAI via Azure, Google Cloud / Vertex, Google OAuth, Apple, and Paddle
  for billing).
- We're legally compelled (court order, lawful subpoena). We will notify
  you unless prohibited by law.
- You explicitly ask us to (for example, exporting your data to another
  service at your request, or authorizing ChatGPT or Claude to read your Nod
  meetings). OpenAI and Anthropic act as user-selected recipients in that
  connector flow, not as Nod subprocessors; their own terms and privacy notices
  apply after the selected client receives the data.
- As part of a business transfer (merger, acquisition, asset sale). We
  will notify you with at least 30 days' notice and you can delete your
  data before any transfer.

One outbound connection is not a data share at all, and we list it here so
the picture is complete: the first time Nod separates speakers on a recording,
it downloads the speaker model from **Hugging Face** (`argmaxinc/speakerkit-coreml`,
a public repository). Like any download, that request discloses your IP address
and app version to them — and nothing else. No audio, no transcript, no account
data is involved, the model is cached on disk afterwards, and Hugging Face
processes no personal data on our behalf, so they are not a subprocessor
(see [Subprocessors](./subprocessors.md)).

---

## 6. International transfers

Your account, transcripts, summaries, and usage metadata are stored in the
European Union (AWS `eu-west-1`, Ireland).

Some subprocessors operate globally and may process data outside the EU:

- **Groq** (speech-to-text), **OpenRouter**, **Anthropic** (via AWS
  Bedrock / Google Vertex), **OpenAI/Azure**, and **Google/Vertex** may
  route requests to US-based infrastructure.
  Transfers rely on the EU
  Commission's adequacy decision for the US (EU–US Data Privacy
  Framework) where applicable, or on Standard Contractual Clauses
  (SCCs) otherwise.
- **Google OAuth** and **Apple** are global services and may process
  authentication / app-distribution data outside the EU under SCCs.

We can provide our SCCs and transfer impact assessments on request to
**dmytro@hellonod.app**.

---

## 7. How long we keep your data

| Data                                 | Retention                                                            |
|--------------------------------------|----------------------------------------------------------------------|
| Account (auth profile)               | Until you delete your account.                                       |
| Connector OAuth grants and refresh-token state | Until you revoke the authorized app, the grant expires, or you delete your account. |
| Device bindings (`user_devices`)     | Until the device signs out, is evicted by the inactivity timeout, or you delete your account (cascade). |
| Meetings (active)                    | Until you delete them.                                               |
| Meetings (in trash)                  | 30 days. A nightly Postgres job permanently deletes anything older. |
| Meeting transcripts                  | Same as the parent meeting (cascade delete).                         |
| Transcript embeddings, session chats, entity links | Same as the parent meeting (cascade delete). Extracted entities themselves are per-user and removed on account deletion. |
| Unclaimed iOS onboarding progress (`onboarding_events`) | 30 days, then a scheduled job deletes it. Declining analytics sends no row. |
| Claimed onboarding and product interaction events (`onboarding_events`, `product_events`) | 24 months at most; removed immediately on account deletion. |
| Share interaction events (`share_product_events`) | 24 months. They contain a random browser-session ID and event name, not the share token or meeting content. Revoking/deleting the share removes them. |
| Website acquisition touches, account attribution, and aggregate Google Ads campaign data | 400 days. A scheduled job deletes older rows. Sign-in relays expire after 24 hours and are removed after expiry. |
| Screen observations (`screen_observations`) | The expiry set when captured — **14 days by default**, changeable in Settings. A scheduled job deletes expired rows. Empty unless you switched ambient context on; deletable at any time; removed on account deletion (cascade). |
| Consent acknowledgements             | 6 years from the date of acknowledgement (legal-defence window).     |
| Usage metadata                       | 24 months, then aggregated and anonymised.                           |
| Encrypted database backups           | 7 days rolling.                                                      |
| Server logs (OpenRouter calls, etc.) | 30 days.                                                             |

When you delete your account from **Settings → Privacy**, we erase your
auth profile, meetings (active and trashed), transcripts, summaries, chats,
entities, labels, device bindings, usage rows, onboarding and product events, and
subscription row immediately — the deletion cascades the moment you confirm it. We retain
your consent acknowledgement rows for the legal-defence window above; these
become orphaned (`user_id` set to NULL) and are no longer linked to you in
any externally-resolvable way.

---

## 8. Your rights

Under the EU/UK GDPR (and equivalents in California, Brazil, Canada, etc.)
you have the following rights. To exercise any of them, email
**dmytro@hellonod.app**. We respond within 30 days.

- **Access & Portability** — export **all** the personal data we hold
  about you as a single machine-readable JSON file, yourself, at any time,
  from **Settings → Privacy → Export my data** — no request needed. You can
  also export any individual meeting as a local Markdown file (with YAML
  frontmatter) from the app.
- **Rectification** — correct inaccurate data.
- **Erasure** — delete your account and all associated personal data
  yourself, immediately, from **Settings → Privacy → Delete account**. This
  erases your auth profile, meetings, transcripts, summaries, chats,
  entities, labels, devices, usage, and subscription rows server-side; your
  consent-acknowledgement audit rows are retained but anonymised (see
  Section 7). You can also delete individual meetings yourself from the app.
- **Restriction** — ask us to pause processing while a dispute is
  resolved.
- **Objection** — object to processing based on legitimate interest
  (Sections 3.3, 3.4, and 3.5 above).
- **Withdraw consent** — where processing is based on consent, withdraw
  it at any time (does not affect prior processing).
- **Lodge a complaint** with your local data protection authority. EU
  residents may complain to the supervisory authority in their country
  of residence. Nod is currently operated by an individual rather than a
  registered company, so there is no designated lead
  supervisory authority — your home-country authority is the right
  contact.

We do **not** make automated decisions with legal or similarly significant
effects about you.

---

## 9. Security

Encryption in transit (TLS 1.2+, default TLS 1.3, lower protocols
rejected), encryption at rest (AES-256), Row-Level Security on every
table, secrets isolated server-side. Detail in our [Security page](./security.md).

If you discover a vulnerability, please email **dmytro@hellonod.app**.
Nod is built by one person right now, so there is no 24/7 on-call rotation
— but every report goes straight to the founder and is acted on as quickly
as possible. We're happy to publicly credit researchers.

In case of a personal data breach that's likely to result in a risk to
your rights and freedoms, we will notify the relevant supervisory
authority within 72 hours and notify affected users without undue delay.

---

## 10. Children

Nod is not directed at children under 16. We do not knowingly collect
personal data from children under 16. If you believe a child has signed
up, contact us and we will delete the account.

---

## 11. Cookies

The Nod macOS app does not use cookies (it's a native app, not a
website). The marketing site stores your analytics choice and a random
first-party visitor ID in browser local storage. If you allow analytics,
Google Analytics and Google Ads may set measurement and advertising cookies.
They do not load after a decline. The complete names, purposes, durations, and
controls are in our [Cookie Policy](./cookies.md).

---

## 12. Changes to this policy

We may update this policy from time to time. When we make a material
change we will:

- Bump the **Last updated** date at the top.
- Email all account holders at least 30 days before the change takes
  effect, unless the change is to your benefit or required by law in
  less time.
- Archive previous versions and make them available on request.

---

## Contact

- Privacy questions and rights requests: **dmytro@hellonod.app**
- Security: **dmytro@hellonod.app**
- Everything else: **dmytro@hellonod.app**

---

> **Operator's note:** This document is a working draft tied to Nod's
> actual data flows as of the date above. It must be reviewed by a
> qualified privacy lawyer before publication, in particular sections 1
> (controller entity), 6 (transfer mechanisms), 8 (supervisory
> authority), and the retention windows in section 7.
