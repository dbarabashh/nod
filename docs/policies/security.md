# Security & Privacy

_Last updated: 2026-06-21_

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

We also do not allow our subprocessors to train on your data. The LLM and
Whisper calls go through OpenRouter, where we have:

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
  `chat_messages`. (The cross-session "Ask Nod" chat is not persisted.)
- **Entities.** People, projects, and topics extracted from your sessions
  (`entities` + `meeting_entities`) so related sessions can be linked.
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
| Whisper transcription | OpenAI via Azure OpenAI  | (no-train)        |
| Text embeddings       | Supabase Edge runtime (`gte-small`) | in-region, no external provider |
| LLM summaries         | Google Gemini via Vertex | (no-train)        |

- Daily encrypted backups of the Postgres database, retained 7 days.
- All HTTPS endpoints and direct database connections enforce TLS 1.2+
  (TLS 1.3 by default; TLS 1.1 and below are rejected).
- Per-user Row-Level Security on every table in the `public` schema.

---

## How data flows

```
You ──► Nod (your Mac) ──► Supabase Edge Function (llm-proxy) ──► OpenRouter ──► Whisper / Gemini
                          │
                          └─► Supabase Postgres (transcripts, summaries, usage logs)
```

The OpenRouter API key never touches your Mac. The app sends requests to our
own Supabase Edge Function (`llm-proxy`), authenticated with your Supabase
JWT. The Edge Function attaches the OpenRouter key (stored only in Supabase
secrets, readable only from the function's runtime) and forwards the call
upstream.

Audio bytes are forwarded once per ~5-second chunk and never written to
durable storage anywhere in this chain — not on your Mac, not in our
database, not by OpenRouter, and not by the upstream Whisper provider
(routed through Azure OpenAI under their no-train commitment).

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
