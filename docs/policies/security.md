# Security & Privacy

_Last updated: 2026-07-22_

> **Nod is in private beta.** It's built and operated by an individual
> developer (Dima Barabash), not a registered company. We've made the
> security and privacy decisions documented below to be defensible for a
> production product — but we want you to know exactly where we stand.

Nod records your meetings on your Mac and turns them into notes. Capture and
voice detection run on-device; transcription and summarization run in the EU
cloud under Zero Data Retention, with as little data leaving your machine as
possible and no audio ever stored. This page documents exactly how that works.

---

## Trust at a glance

- **Hosted in the EU.** All stored data lives in Supabase (AWS `eu-west-1`,
  Ireland).
- **Encrypted in transit and at rest.** TLS 1.2+ on the wire (TLS 1.3 by
  default; TLS 1.1 and below are rejected). AES-256 at rest in Postgres.
  Direct database connections also require SSL.
- **We do not train any models on your data.** Neither do our subprocessors —
  we route only through providers with Zero Data Retention and "may train on
  request data" disabled.
- **Audio is never stored.** Chunks are transcribed in ~5-second windows and
  the bytes are released as soon as the transcript returns. Only the
  transcript and your notes are persisted.
- **No screenshots, no screen recording — ever.** What Nod reads from the
  screen it reads as *text*, through the macOS accessibility interface. There
  is no image captured, stored, or transmitted anywhere in the product.
- **Ambient context is off until you turn it on.** Nod can keep a
  time-limited index of text from windows you haven't excluded, so you can ask
  it about what you were working on. It ships **off**, you switch it on, you
  choose how long it is kept, and you can exclude any app, category, or site.
- **Private by default.** No team workspaces, no shared notes, no public
  links — your meetings are visible only to you.
- **No SOC 2 yet.** Nod is in private beta. Independent audit isn't something
  we've started — we'll publish progress here when it is. GDPR DPA available
  on request.

---

## The basics

Nod is a macOS app that sits in a small floating panel on the left of your
screen. You start a recording manually — Nod never records without you pressing
record. While a meeting is running, Nod captures two audio streams locally:

1. Your microphone (via macOS `AVAudioEngine`).
2. The other side of the conversation, via system audio (`ScreenCaptureKit`).

An on-device voice-activity model (Silero VAD) decides where each utterance
starts and ends, so the streams are cut into complete chunks on real pauses.
Each chunk is sent to Whisper in the cloud — routed through our EU proxy under
Zero Data Retention — and the audio bytes are discarded immediately after the
transcript comes back. Transcription and summarization are not on-device. The
transcript and the AI-generated summary are saved to your private Nod account.

Nod doesn't join meetings as a bot. There is no calendar integration, no
Zoom/Meet/Teams hook, no automated chat message. It works with any app that
plays audio on your Mac.

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

Nod reads from your screen in two distinct ways. Both read **text, not
pixels** — via the macOS accessibility interface, the same one screen readers
use. Nod takes **no screenshots** and records **no video**, in either mode.
Both require the macOS **Accessibility** permission, which you grant in System
Settings; without it, neither runs.

**1. Call participants — while a session records.**

- **One window.** A running conferencing app (Zoom, Teams, Webex, Slack), or —
  for a browser — only a window whose title names a call. Other windows and
  tabs are skipped without being read.
- **A couple of samples per session**, not a loop. A participant list changes
  rarely.
- **Count on-device, names once to the summariser.** The participant count
  drives on-device speaker clustering and never leaves your Mac. The names go
  once, alongside the transcript, to the summarising model through our EU proxy
  under Zero Data Retention, so a summary can say "Alina" instead of
  "Speaker 2". The list itself is not stored — it is dropped with the session.

**2. Ambient context — only if you switch it on.**

This is the part that reads beyond a meeting, so it is the part with the
tightest controls:

- **Off by default.** It never arrives switched on with an app update. You
  turn it on in Settings → Privacy.
- **What it stores.** Every ~5 seconds it reads the text of the window you
  are actually looking at and stores it in `screen_observations`: the text,
  the app, the window title, and a timestamp. No images, no keystrokes, no
  clipboard, no passwords field contents.
- **Bounded retention.** Every row carries an expiry — 14 days by default, and
  you choose. A scheduled job deletes expired rows server-side, so context
  stops existing even if you never open the app again.
- **Deduplicated.** An unchanged screen is one row, not one row per tick.
- **Your blocklist wins.** The exclusion check runs *before* anything is read,
  not after. An excluded app or window is never traversed at all.
- **Deletable.** You can delete observations the same way you delete a
  meeting, and account deletion takes them with it.

We are stating the trade plainly: with ambient context on, Nod holds a
time-limited record of text you had on screen. That is more than a meeting
recorder holds. It is off unless you decide otherwise, it is bounded, and it
is yours to delete.

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
- **Subscription state.** One row per account in `subscriptions` — your plan,
  its status, billing-period and trial dates, and the Paddle customer and
  subscription identifiers we use to reconcile billing events. **No card data**
  — payment details stay with Paddle, our Merchant of Record.

All of this is stored in Supabase Postgres in `eu-west-1`, encrypted at rest,
scoped per-user with Row-Level Security so one user cannot read another
user's data.

### Access control

- Your notes are **private by default**. There is no sharing, no team mode,
  no public links today.
- You can delete any individual meeting from the app. Deletes are soft: the
  meeting moves to a trash that's automatically and permanently purged 30
  days later by a nightly Postgres job.
- You can delete your **entire account** yourself, immediately, from
  **Settings → Privacy → Delete account**. Confirming it deletes your
  `auth.users` row, which cascades to every table holding your data
  (meetings, transcripts, summaries, chats, entities, labels, embeddings,
  devices, usage, subscription). The only thing kept is your anonymised
  consent-acknowledgement audit rows (legal-defence record, `user_id`
  nulled). Any live Paddle subscription is cancelled first so you're never
  billed again.
- You can export **all** of your data yourself, as a single machine-readable
  JSON file, from **Settings → Privacy → Export my data** (GDPR right of
  access / portability). No request needed.
- You can export any single meeting yourself as a local **Markdown** file
  (YAML frontmatter + summary + transcript) from the app — your notes are
  yours to take out, in a plain-text format any editor (e.g. Obsidian) reads.

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
No screenshots, no video — what Nod reads, it reads as text. By default the
only thing it reads is the participant list of your call window, while a
session records, to tell speakers apart. Separately, you can switch on
**ambient context**, which keeps a time-limited index of text from windows you
haven't excluded so you can ask Nod about what you were working on. That is
off until you turn it on, its retention is yours to set, and Settings →
Privacy lets you exclude any app, website category, or specific site before
anything is read.

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
No, and we don't want to overpromise. Nod is in private beta and SOC 2 work
hasn't started. We'll update this page when it does. In the meantime we're
happy to walk through our actual controls — email **dbarabashdev@gmail.com**.

**Where can I report a vulnerability?**
**dbarabashdev@gmail.com**. Nod is built by one person right now, so there's
no 24/7 on-call team — but every report goes straight to the founder and we
act on it as quickly as we can. We're happy to credit researchers publicly.

**Can I use my own AI provider / private cloud?**
Not in the consumer app. We're evaluating a "bring your own key" mode for
the team tier — let us know at **dbarabashdev@gmail.com** if you need this.

---

## Contacts

- General privacy questions: **dbarabashdev@gmail.com**
- Security vulnerabilities: **dbarabashdev@gmail.com**
- Everything else: **dbarabashdev@gmail.com**
