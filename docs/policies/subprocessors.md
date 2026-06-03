# Subprocessors

_Last updated: 2026-06-02_

A subprocessor is a third party that processes personal data on our behalf
when you use Nod. We use the minimum number of subprocessors required to
deliver the product, and we publish the full list here so you can audit it.

We give 30 days' notice before adding a new subprocessor to this list. To
subscribe to change notifications, email **dbarabashdev@gmail.com**.

---

## Current subprocessors

| Subprocessor                | Purpose                                  | Data shared                                                       | Location           | Training on your data | DPA / no-train basis |
|-----------------------------|------------------------------------------|-------------------------------------------------------------------|--------------------|-----------------------|----------------------|
| **Supabase, Inc.**          | Auth, Postgres database, Edge Functions  | Email, OAuth identity, meeting transcripts, summaries, chat messages, transcript embeddings, extracted entities, usage logs | AWS `eu-west-1` (Ireland) | No                    | Supabase DPA         |
| **OpenRouter, Inc.**        | LLM, Whisper, and embedding request routing | Audio chunks (transient), transcript text, chat messages, query text | Routed via no-train providers | No                    | Zero Data Retention enabled; "may train on request data" routes disabled |
| **OpenAI** (via Azure OpenAI Service) | Whisper speech-to-text, text embeddings (`text-embedding-3-small`) | Audio chunks (transient, ~5 s windows); transcript chunk text (for embeddings) | Routed by OpenRouter | No                    | Azure OpenAI no-train commitment |
| **Google LLC** (via Google Vertex AI) | LLM summarisation               | Transcript text, system prompt                                    | Routed by OpenRouter | No                    | Vertex AI no-train commitment |
| **Google LLC** (OAuth)      | Authentication (sign-in with Google)     | Your Google email, OpenID profile claims                          | Global             | No                    | Google OAuth ToS     |
| **Apple, Inc.**             | macOS app distribution & code signing    | Crash logs (if you opt-in via System Settings), receipt validation | Global             | No                    | Apple Developer Agreement |

Audio is never stored by any subprocessor — it exists only for the duration
of a single Whisper request and is discarded by the upstream provider as
soon as the transcription completes.

## Planned subprocessors (post-launch)

| Subprocessor      | Purpose                              | Status                                 |
|-------------------|--------------------------------------|----------------------------------------|
| **Paddle.com**    | Subscription billing, VAT remittance | Will be added when paid tier launches  |

---

## What we do **not** use

- **No analytics SDKs.** Nod does not embed PostHog, Mixpanel, Amplitude,
  Segment, Google Analytics, or Sentry. We have no third-party telemetry in
  the macOS app.
- **No advertising networks.** Nod shows no ads and shares no data with
  ad-tech platforms.
- **No meeting-platform bots.** We do not deploy a bot into Zoom, Meet, or
  Teams — Nod captures audio locally via macOS APIs only.

---

## Change history

| Date       | Change                                        |
|------------|-----------------------------------------------|
| 2026-05-27 | Initial published list.                       |
| 2026-06-02 | Added text-embedding model (via OpenRouter) for cross-session search; noted chat messages, embeddings, and extracted entities stored in Supabase. |

---

Questions? **dbarabashdev@gmail.com**.
