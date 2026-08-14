# Security & Privacy

_Last updated: 2026-08-14_

_[Calendar access](#calendar-access), [Organizations](#organizations), and the
email-delivery section under [How data flows](#how-data-flows) are **advance
notice**: none of the three is in the released app, and the calendar one stays
off until you switch it on. Where this page describes Nod as sitting in the
notch, the released version still runs as a floating panel on the left of your
screen._

> The security and privacy decisions documented below are made to be
> defensible for a production product, and every claim on this page is
> tied to code you can hold us to.

Nod records your meetings on your Mac and turns them into notes. Capture and
voice detection run on-device; transcription and summarization run on hosted
inference providers under Zero Data Retention, with as little data leaving your
machine as possible and no audio ever stored. Everything Nod keeps is stored in
the EU. This page documents exactly how that works.

---

## Trust at a glance

- **Stored in the EU.** All stored data lives in Supabase (AWS `eu-west-1`,
  Ireland). Inference is the exception, documented under
  [Infrastructure](#infrastructure): transcription runs on providers hosted
  outside the EU, under EU-U.S. Data Privacy Framework adequacy or standard
  contractual clauses, with Zero Data Retention and no training. No audio is
  stored at either end.
- **Encrypted in transit and at rest.** TLS 1.2+ on the wire (TLS 1.3 by
  default; TLS 1.1 and below are rejected). AES-256 at rest in Postgres.
  Direct database connections also require SSL.
- **We do not train any models on your data.** Neither do our subprocessors —
  we route only through providers with Zero Data Retention and "may train on
  request data" disabled.
- **Audio is never stored.** Chunks are transcribed in ~5-second windows and
  the bytes are released as soon as the transcript returns. Only the
  transcript and your notes are persisted.
- **No screen recording, and no image ever saved.** What Nod keeps from your
  screen is always *text*, read through the macOS accessibility interface.
  With ambient context on, a window macOS cannot describe — Slack, Figma and
  other Electron or canvas-drawn apps — is converted to text from its pixels
  on your Mac; that image lives only in memory for the moment recognition
  takes and is never written to disk or transmitted anywhere.
- **Ambient context is off until you turn it on.** Nod can keep a
  time-limited index of text from windows you haven't excluded, so you can ask
  it about what you were working on. It ships **off**, you switch it on, you
  choose how long it is kept, and you can exclude any app, category, or site.
  Personal messengers are excluded before you configure anything.
- **Private by default.** Your meetings are visible only to you, unless you
  create a share link yourself (see [Access control](#access-control)). In an
  organization the default holds: an administrator cannot read what members
  record unless the organization switches that on, and ambient screen text, your
  search index and your cross-session threads stay unreadable either way (see
  [Organizations](#organizations)).
- **Connectors are read-only and resource-bound.** Official ChatGPT and Claude
  access uses OAuth 2.1 with PKCE, rotating refresh tokens, exact audience
  validation, and only `meetings:read`. Connector tokens cannot query database
  tables directly.
- **No SOC 2 yet.** It's planned, but the independent audit hasn't started, so
  there's no report to send. We'll publish progress here when that changes.
  GDPR DPA available on request.

---

## The basics

Nod is a macOS app that runs in a small window of its own — a floating panel
today, moving into the notch at the top of your screen in a coming version. You
start a recording manually — Nod never records without you pressing record. While
a meeting is running, Nod captures two audio streams locally:

1. Your microphone (via macOS `AVAudioEngine`).
2. The other side of the conversation, via system audio (`ScreenCaptureKit`).

An on-device voice-activity model (Silero VAD) decides where each utterance
starts and ends, so the streams are cut into complete chunks on real pauses.
Telling voices apart afterwards also happens on your Mac, on a speaker model
(pyannote, via Argmax SpeakerKit) that Nod downloads once from Hugging Face on
first use and keeps on disk. That download sends nothing but the request itself
— no audio, no transcript, no account — and every diarised meeting after it
works offline.
Each chunk is sent to Whisper in the cloud — routed through our own proxy under
Zero Data Retention — and the audio bytes are discarded immediately after the
transcript comes back. The proxy runs in the EU; the inference providers it
forwards to do not (see [Infrastructure](#infrastructure)). Transcription and summarization are not on-device. The
transcript and the AI-generated summary are saved to your private Nod account.

Nod doesn't join meetings as a bot. No Zoom/Meet/Teams hook, no automated chat
message, and no connected calendar account — a coming version will be able to
read the calendar already on your Mac, on the device and only if you switch it on
([Calendar access](#calendar-access)), but it never signs in to Google or
Microsoft on your behalf. It works with any app that plays audio on your Mac.

---

## How we handle your data

### Model training

**We do not train any models on your data.** Period.

We also do not allow our subprocessors to train on your data.

Speech-to-text runs primarily on **Groq**, whose Services Agreement prohibits
using inputs or outputs to train any model and which retains no customer data
by default (only transient error/abuse logs, ≤ 30 days).

The LLM and fallback Whisper calls go through OpenRouter, where we have:

- Enabled **Zero Data Retention** for all non-frontier model routes.
- **Disabled** "paid endpoints that may train on request data".
- **Disabled** "free endpoints that may train on request data".
- **Disabled** "free endpoints that may publish prompts".
- **Disabled** first-party endpoints for Anthropic, OpenAI, and Google — all
  traffic routes through enterprise endpoints (AWS Bedrock, Azure OpenAI,
  Google Vertex AI), which contractually do not use customer data for
  training.

### Audio recordings

Nod **does not store any audio**. Audio is held in memory only long enough to
chunk it (~5 seconds), normalise it, and POST the chunk to Whisper through our
proxy. As soon as the transcript returns, the audio bytes are released. There
is no recording file, no waveform export, no cloud-stored audio — ever.

### Screen access

Nod reads from your screen in three distinct ways. All three keep **text, never
an image** — primarily via the macOS accessibility interface, the same one
screen readers use. Nod records **no video** and saves **no image**, in any of
them. Modes 1 and 2 require the macOS **Accessibility** permission, which you
grant in System Settings; without it, neither runs. Mode 3 reads only window
*titles*, through the **Screen Recording** permission Nod already needs to hear
a meeting.

Ambient context (mode 2) has one exception: an app that tells macOS nothing
about its contents is read from its pixels and converted to text on-device, at
most once every 20 seconds, and only after the accessibility read came up
short. It needs the **Screen Recording** permission and macOS 14 or later, and
it is skipped without either. Your blocklist is checked before that read, not
after — an excluded window is never recognised.

**1. Call participants — while a session records.**

- **One window.** A running conferencing app (Zoom, Teams, Webex, Slack,
  Discord), or — for a browser — only a window whose title names a call. Other windows and
  tabs are skipped without being read.
- **A couple of samples per session**, not a loop. A participant list changes
  rarely.
- **Count on-device, names once to the summariser.** The participant count
  drives on-device speaker clustering — the model runs on your Mac's Neural
  Engine, and the audio it clusters never leaves your machine. The names go
  once, alongside the transcript, to the summarising model through our own proxy
  under Zero Data Retention, so a summary can say "Alina" instead of
  "Speaker 2". The list itself is not stored — it is dropped with the session.

**2. Ambient context — only if you switch it on.**

This is the part that reads beyond a meeting, so it is the part with the
tightest controls:

- **Off by default.** It never arrives switched on with an app update. You
  turn it on in Settings → Privacy.
- **What it stores.** Every ~5 seconds it reads the text of the window you
  are actually looking at and stores it in `screen_observations`: the text,
  the app, the window title, and a timestamp. No image is ever stored — not
  even when the text came from recognising one — and no keystrokes, no
  clipboard, no password-field contents.
- **Bounded retention.** Every row carries an expiry — 14 days by default, and
  you choose. A scheduled job deletes expired rows server-side, so context
  stops existing even if you never open the app again.
- **Deduplicated.** An unchanged screen is one row, not one row per tick.
- **Your blocklist wins.** The exclusion check runs *before* anything is read,
  not after. An excluded app or window is never traversed at all.
- **Messengers start excluded.** WhatsApp, Telegram, Messages, Messenger,
  Signal, Viber and Discord are on the blocklist before you configure
  anything — the window people look at most is a private conversation with
  someone who never agreed to any of this. They are removable entries, not
  fixed rules: take one off the list and it stays off.
- **Deletable.** You can delete observations the same way you delete a
  meeting, and account deletion takes them with it.

We are stating the trade plainly: with ambient context on, Nod holds a
time-limited record of text you had on screen. That is more than a meeting
recorder holds. It is off unless you decide otherwise, it is bounded, and it
is yours to delete.

**3. Meeting detection — noticing a call has started.**

- **Titles, not contents.** Which apps are running, which app holds the
  microphone (macOS names it; no audio is read), and the window titles of
  conferencing apps. No window's contents
  are read, in any app, and the accessibility interface is not used at all.
- **Nothing is stored.** A title is matched in memory and dropped: no row, no
  file, nothing transmitted.
- **It cannot start a recording.** It raises a card. Clicking it goes through
  the same consent and language steps as pressing Start yourself.
- **It wraps up after the call.** A recording Nod started for a detected call
  finishes and summarises about 30 seconds after that call disappears, with a
  visible countdown and a keep-recording button.
- **Off in one click.** Settings → General disables it; the card offers "Never
  for <app>"; a blocklisted app is never detected.

### Calendar access

**Advance notice — not in the released app.** The released app never asks macOS
for calendar access and never reads one. What follows describes the version that
introduces it.

Separate from screen access, and off until you switch it on. It exists for one
job: to name the meeting a detected call belongs to, so the offer to record can
tell you what you already discussed and what was left open.

- **Not a connected account.** No Google or Microsoft sign-in, no OAuth, no
  token, no calendar API. Nod reads the calendar already on your Mac, through
  the macOS **Calendars** permission — the same kind of grant as the
  microphone.
- **Off by default.** You switch it on in Settings → General, and macOS asks
  you separately. An app update never turns it on.
- **On a timer while it is switched on.** About every 20 seconds, so Nod can
  tell you a meeting is starting before you have opened anything — plus once
  when a call is detected and once when a recording finishes, since invitations
  are often written after a call has already begun. Switching the feature off
  stops the timer.
- **It still cannot start a recording.** A meeting that is starting raises a
  card with a button, exactly like a detected call. Nothing records until you
  press it.
- **The entry and who was invited.** Title, start and end, whether you
  declined, whether it holds a video-call link, and each invitee's name (or
  address, where the invitation carries no name) plus which one is you. Rooms
  and equipment are skipped, and so is anyone who declined.
- **The names go where the conferencing app's already did.** They are used to
  count how many voices other than yours the recording should hold, and to put
  a name to a voice in your summary — the same path and protections as the
  participant list described under Screen access, and a replacement for it.
  Nothing else is kept: the title is compared against your own past sessions on
  the device and dropped, and no record of the event is ever written.
- **Read-only, always.** Nod never creates, edits, or deletes a calendar entry.

### What we do store

- **Transcripts.** One row per finalised Whisper chunk in
  `meeting_transcripts`, with the speaker side (`me` / `them`) and timestamp.
  This also covers any transcripts you choose to import from Granola (see
  "Importing from other apps" below).
- **Meeting summaries.** The AI-generated summary text in `meetings`, plus the
  session type (`kind`: meeting / voice note / media).
- **Transcript embeddings.** To let you ask questions across your sessions, we
  store each transcript chunk and its vector embedding in `session_embeddings`.
  The chunk text is a copy of transcript content you already stored; the vector
  is produced **in-region by Supabase's built-in `gte-small` model**, inside our
  Edge Function — the chunk text is not sent to any external embedding provider
  (see Subprocessors). Search is scoped to your own rows by Row-Level Security.
- **Your profile.** The optional name / role / focus you enter (in `profiles`),
  used to give the AI context. You can view, edit, or clear it in Settings.
- **Session chats.** Messages you exchange with the per-session assistant, in
  `chat_messages`.
- **Cross-session chats ("Ask Nod").** Each conversation is saved as a thread
  (`knowledge_threads`) with its messages (`knowledge_messages`), so you can
  reopen and continue it. A saved message also keeps the sessions the answer
  drew on and the excerpts it quoted, so a reopened answer still shows its
  evidence. You can delete any thread from the Ask Nod list; deleting a thread
  deletes its messages with it.
- **Which source you opened.** When you click through from an answer to the
  session it cited, we record that click (`retrieval_feedback`): the question
  you asked, which session you opened, and its position in the list. This is
  what lets search learn which sessions actually answer which questions. It is
  your own content, under the same Row-Level Security as everything else.
- **Entities.** People, projects, and topics extracted from your sessions
  (`entities` + `meeting_entities`) so related sessions can be linked.
- **Screen observations — only with ambient context on.** Text read from
  windows you haven't excluded, in `screen_observations`, with the app, the
  window title, and an expiry. Empty unless you switched the feature on;
  purged automatically when rows expire.
- **Account profile.** Your email and Google OAuth identity, stored in
  Supabase Auth.
- **Consent acknowledgements.** An audit row each time you click "Acknowledge
  & Start" on the recording disclaimer, with the disclaimer version and your
  app version. No meeting content.
- **Usage metadata.** Per-API-call: model used, token count or audio seconds,
  upstream cost, and HTTP status. We use this to enforce per-account quotas
  and inform pricing. No content.
- **Product interaction events.** Bounded event names and categorical
  properties for onboarding, capture reliability, content views, Ask,
  copy/export, paywall and checkout. The database rejects arbitrary properties;
  no meeting content, question, answer, title, clipboard value, share token, or
  raw error is accepted. App events stay in Supabase and are never sent to
  Google.
- **Subscription state.** One row per account in `subscriptions` — your plan,
  its status, billing-period and trial dates, and the Paddle customer and
  subscription identifiers we use to reconcile billing events. **No card data**
  — payment details stay with Paddle, our Merchant of Record.
- **Allowance and top-ups.** Service-owned rows tie a bought pack of hours, and
  the checkout that created it, to immutable Paddle transaction identifiers. You
  can read your own top-ups and rewards; the payer history, provider adjustments,
  and reward payout ledger have no client access at all. A purchase that cannot be
  matched to its own checkout intent is parked for review instead of being
  credited automatically.
- **Meeting-start leases.** Before a recording begins, a short-lived row binds
  that recording's ID to your account. Transcription accepts the ID only while the
  lease is valid, and the lease is renewed by the recording itself. That is how the
  hour allowance is enforced at the START of a meeting and can never cut off one
  already running — and a crashed or offline app frees its own slot in minutes
  rather than locking recording out.

All of this is stored in Supabase Postgres in `eu-west-1`, encrypted at rest,
scoped per-user with Row-Level Security so one user cannot read another
user's data.

### Access control

- Your notes are **private by default**. Nothing is readable by anyone else
  until you explicitly create a share link for one specific meeting. A personal
  account shares nothing with anyone; what changes inside an organization is set
  out under [Organizations](#organizations).
- **Share links are opt-in, summary-only, and revocable.** Creating one mints
  an opaque random token; whoever holds the link can read *that meeting's
  summary* and nothing else, never the transcript and never your other
  meetings. Anonymous viewers never touch the `meetings` table (Row-Level
  Security forbids it); they read through a function that only returns recap
  fields. At most one live link exists per meeting. Revoking it, or deleting
  the meeting, kills access immediately.
- You can delete any individual meeting from the app. Deletes are soft: the
  meeting moves to a trash that's automatically and permanently purged 30
  days later by a nightly Postgres job.
- You can delete your **entire account** yourself, immediately, from
  **Settings → Privacy → Delete account**. Confirming it deletes your
  `auth.users` row, which cascades to every table holding your data
  (meetings, transcripts, summaries, chats, entities, labels, embeddings,
  devices, usage, subscription, top-ups, referrals, rewards, leases, and email
  choices). The only thing kept is your anonymised
  consent-acknowledgement audit rows (legal-defence record, `user_id`
  nulled). Any live Paddle subscription is cancelled first so you're never
  billed again.
- You can export **all** of your data yourself, as a single machine-readable
  JSON file, from **Settings → Privacy → Export my data** (GDPR right of
  access / portability). No request needed.
- You can export any single meeting yourself as a local **Markdown** file
  (YAML frontmatter + summary + transcript) from the app — your notes are
  yours to take out, in a plain-text format any editor (e.g. Obsidian) reads.

### Organizations

An organization is for people whose employer holds the account rather than they
do. It has members with roles (owner, administrator, member) and can be divided
into teams. Nobody joins one by their own action: membership is written only by
the server, after an existing administrator invites the address — an app that
could add itself to an organization could add itself to any organization whose
identifier it learned, and identifiers are not secrets.

A recording belongs either to you or to an organization, and the database decides
which. The app states a context; the server checks it against live membership and
rejects a claim to an organization you are not in. Once a recording belongs to an
organization it cannot be moved to a different one, by anyone, including that
organization's owner.

Two things the organization decides, and they are separate on purpose:

- **Whether a private context exists inside it.** An organization may require
  that everything its members record while working there belongs to it. When it
  does, there is no client-side way to mark a session personal — the boundary
  stops being yours to draw, and you should know that before you record.
- **Whether administrators may read what members recorded.** This is **off by
  default** and is its own switch rather than something being an administrator
  implies. With it off, an administrator sees that a meeting exists in their
  organization's account and cannot read it. With it on, they can read meetings,
  transcripts, action items and per-meeting chats belonging to their
  organization.

What administrators cannot read in either case: ambient screen text, the search
index built from your transcripts, and your cross-session "Ask Nod" threads. No
administrative read path exists for those — not one that is switched off, one
that is not written. Ambient capture in particular is something you switch on for
yourself, exclude apps from, and set the lifetime of ([Screen
access](#screen-access)); an administrator browsing it would not be a wider
version of that promise but a different one, and it would arrive as its own
decision with its own line on this page.

Being in the same organization gives members nothing. A colleague reads your
recordings only through the administrator switch above or a share link you made
yourself — never simply by being on the roster.

An organization keeps an audit record of administrative actions taken inside it.

None of this reaches a personal account. Every rule here applies only to a
recording that carries an organization, and a personal recording carries none —
the machinery is inert for you, not merely unused.

### Official AI connectors

The hosted MCP server accepts OAuth Bearer tokens only after Supabase Auth
confirms the token is active and its issuer, audience, expiry, subject,
`client_id`, database role, and `meetings:read` permission all match the active
environment. Missing or invalid credentials receive the protected-resource
metadata challenge required by OAuth clients.

The `mcp_connector` database role has no direct table, sequence, or function
privileges. The MCP Edge Function uses server credentials only after
authentication and applies the token subject as a mandatory `user_id` filter to
every meeting and transcript query. Tools are annotated read-only and
non-destructive. Transcript responses default to 100 segments, never exceed 250
segments or 100,000 characters, and use an opaque continuation cursor.

Users see the client and redirect address on the consent page and can deny the
request, revoke a grant, or reconnect. Supabase rotates refresh tokens and
rejects revoked grants. OAuth has an independent server-side kill switch. The
older `nod_pat_` route remains isolated behind deprecation and sunset headers
during migration, then returns `410 Gone`; disabling OAuth before that sunset
preserves it as the rollback path.

### Importing from other apps

If you previously used **Granola**, Nod can import your past meetings'
transcripts from Granola's offline cache on your Mac
(`~/Library/Application Support/Granola/cache-v3.json`), triggered manually
from Settings. The import reads a **local file only** — no Granola account and
no network call to Granola — and is fully offline. Only transcript text,
speaker side, and timestamps are imported (not Granola's notes). Imported
meetings land in the same `meetings` / `meeting_transcripts` tables, under the
same per-user Row-Level Security, and are deletable like any other meeting.

### Participant consent

Nod runs locally on **your** Mac and captures system audio without integrating
with Zoom, Meet, or Teams. We do not (and cannot today) post a consent message
into the meeting chat for you. Before your first recording, Nod shows a
one-time disclaimer reminding you to obtain consent from everyone on the
call.

Recording laws differ by jurisdiction — some require all-party consent. See
our [Recording & Consent guide](./consent.md) for a quick reference, and make
sure you comply with the rules where you and your participants are located.

---

## Infrastructure

| Layer                 | Provider                 | Region            |
|-----------------------|--------------------------|-------------------|
| Database              | Supabase Postgres        | AWS `eu-west-1`   |
| Auth                  | Supabase Auth            | AWS `eu-west-1`   |
| Server-side functions | Supabase Edge Functions  | EU                |
| LLM gateway           | OpenRouter               | routed            |
| Whisper transcription | Groq (primary); OpenAI/Azure + OpenRouter (fallback) | US (Groq); routed (no-train) |
| Text embeddings       | Supabase Edge runtime (`gte-small`) | in-region, no external provider |
| LLM summaries & chat  | Anthropic Claude via AWS Bedrock / Vertex (Google Gemini optional) | (no-train) |

- Daily encrypted backups of the Postgres database, retained 7 days.
- All HTTPS endpoints and direct database connections enforce TLS 1.2+
  (TLS 1.3 by default; TLS 1.1 and below are rejected).
- Per-user Row-Level Security on every table in the `public` schema.

---

## How data flows

```
You ──► Nod (your Mac) ──► Supabase Edge Function (llm-proxy) ──┬─► Groq ──► Whisper (speech-to-text, primary)
                          │                                     ├─► OpenRouter ──► Claude (summaries + chat) + Whisper (last-resort)
                          │                                     └─► OpenAI ──► Whisper (fallback)
                          │
                          └─► Supabase Postgres (transcripts, summaries, usage logs)
```

No provider API key ever touches your Mac. The app sends requests to our
own Supabase Edge Function (`llm-proxy`), authenticated with your Supabase
JWT. The Edge Function attaches the provider key (stored only in Supabase
secrets, readable only from the function's runtime) and forwards the call
upstream — speech-to-text to Groq first, with OpenAI and OpenRouter as
fallbacks.

Audio bytes are forwarded once per chunk and never written to durable
storage anywhere in this chain — not on your Mac, not in our database, not
by Groq (no retention by default), and not by any fallback Whisper provider.

---

### Email delivery (advance notice — not active today)

Nothing is sent to our email provider before the notice period in the
[Privacy Policy](./privacy.md) § 3.14 completes — that single gate blocks
delivery, and also blocks synchronising a contact.

When it is active: Supabase stays authoritative for consent, suppression, and
cadence, and the provider is a mirror. A durable send record keyed by campaign and
account prevents sending the same message twice regardless of retries, and it
outlives the 90-day delivery logs. Immediately before each send, consent,
suppression, the gate, and the reason the message qualified are all re-checked, so
a preference changed while a message was queued wins. Complaints and hard bounces
suppress the address at once and cancel anything still queued for it.

Preference links carry an opaque token in the URL fragment only; loading the page
performs a read, and a change requires an explicit confirmation. Open tracking is
disabled, so we cannot tell an email was opened. Click tracking is enabled: links
are rewritten by the delivery provider, and following one records that the link
in that message was followed, and nothing about where you went next.

## Subprocessors

See the full [Subprocessors list](./subprocessors.md). Updated subprocessor
list and DPAs are available on request.

---

## FAQ

**Where is my data stored?**
In Supabase Postgres in the EU (AWS `eu-west-1`), encrypted at rest with
AES-256.

**Do you train any models on my data?**
No. Neither we nor our subprocessors. See [Model training](#model-training).

**Do you store audio recordings?**
No. Audio is chunked, transcribed, and discarded within seconds. Only the
transcript is saved.

**Does Nod take screenshots or watch my screen?**
No video, and no image of your screen is ever saved — what Nod keeps is
text. By default the
only thing it reads is the participant list of your call window, while a
session records, to tell speakers apart. Separately, you can switch on
**ambient context**, which keeps a time-limited index of text from windows you
haven't excluded so you can ask Nod about what you were working on. In that
mode, a window that macOS cannot describe is converted to text from its pixels
on your Mac — the image is never saved or sent anywhere, only the text it
yields. Ambient context is off until you turn it on, its retention is yours to
set, and Settings → Privacy lets you exclude any app, website category, or
specific site before anything is read.

**Can I stop Nod reading a particular app or site?**
Yes. Settings → Privacy holds an exclusion list for apps, categories, and
websites. It is checked before anything is read, so an excluded app is never
traversed in any mode.

**How do you notify other meeting participants?**
We don't — you do. Nod runs locally and doesn't integrate with Zoom/Meet/Teams,
so we can't post into the meeting chat. We show you a one-time consent
reminder before your first recording, and we keep an audit trail of every
acknowledgement.

**Can I delete my data?**
Yes. Per-meeting from the app (30-day trash, then permanently purged), or
your **entire account** instantly from **Settings → Privacy → Delete
account** — it cascades across every table holding your data.

**Can I export my data?**
Yes. From **Settings → Privacy → Export my data** you download everything
Nod holds about you as one machine-readable JSON file (GDPR Articles 15 &
20) — no request needed.

**Do you have SSO / SAML?**
Not yet. Sign-in is via Google OAuth. SAML SSO is planned for the team tier.

**Do you have SOC 2?**
No. It's planned, but the audit hasn't started, so there's no report to send,
and we don't want to overpromise. We'll update this page when that changes. In
the meantime we're happy to walk through our actual controls. Email
**dmytro@hellonod.app**.

**Where can I report a vulnerability?**
**dmytro@hellonod.app**. Nod is built by one person right now, so there's
no 24/7 on-call team — but every report goes straight to the founder and we
act on it as quickly as we can. We're happy to credit researchers publicly.

**Can I use my own AI provider / private cloud?**
Not in the consumer app. We're evaluating a "bring your own key" mode for
the team tier — let us know at **dmytro@hellonod.app** if you need this.

---

## Contacts

- General privacy questions: **dmytro@hellonod.app**
- Security vulnerabilities: **dmytro@hellonod.app**
- Everything else: **dmytro@hellonod.app**
