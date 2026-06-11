# Subprocessors

_Last updated: 2026-06-10_

A subprocessor is a third party that processes personal data on our behalf
when you use Nod. We use the minimum number of subprocessors required to
deliver the product, and we publish the full list here so you can audit it.

We give 30 days' notice before adding a new subprocessor to this list. To
subscribe to change notifications, email **dbarabashdev@gmail.com**.

---

## Current subprocessors

| Subprocessor                | Purpose                                  | Data shared                                                       | Location           | Training on your data | DPA / no-train basis |
|-----------------------------|------------------------------------------|-------------------------------------------------------------------|--------------------|-----------------------|----------------------|
| **Supabase, Inc.**          | Auth, Postgres database, Edge Functions, in-region text embeddings (`gte-small`) for cross-session search | Email, OAuth identity, meeting transcripts, summaries, chat messages, transcript embeddings, extracted entities, usage logs | AWS `eu-west-1` (Ireland) | No                    | Supabase DPA         |
| **OpenRouter, Inc.**        | LLM and Whisper request routing          | Audio chunks (transient), transcript text, chat messages, query text | Routed via no-train providers | No                    | Zero Data Retention enabled; "may train on request data" routes disabled |
| **OpenAI** (via Azure OpenAI Service) | Whisper speech-to-text          | Audio chunks (transient, ~5 s windows)                            | Routed by OpenRouter | No                    | Azure OpenAI no-train commitment |
| **Google LLC** (via Google Vertex AI) | LLM summarisation               | Transcript text, system prompt                                    | Routed by OpenRouter | No                    | Vertex AI no-train commitment |
| **Google LLC** (OAuth)      | Authentication (sign-in with Google)     | Your Google email, OpenID profile claims                          | Global             | No                    | Google OAuth ToS     |
| **Apple, Inc.**             | macOS app distribution & code signing    | Crash logs (if you opt-in via System Settings), receipt validation | Global             | No                    | Apple Developer Agreement |
| **Paddle.com Market Limited** | Merchant of Record — subscription billing, payment processing, VAT/sales-tax remittance, invoicing, refunds | Name, email, billing address and country, and payment-method details you enter at checkout; subscription and transaction records | UK; global payment processing | No | Paddle DPA; Paddle acts as Merchant of Record |

Audio is never stored by any subprocessor — it exists only for the duration
of a single Whisper request and is discarded by the upstream provider as
soon as the transcription completes.

Nod never receives or stores your full card details — those are handled
entirely by Paddle as Merchant of Record.

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

## How data flows

```
You ──► Nod (your Mac) ──► Supabase Edge Function (llm-proxy) ──► OpenRouter ──► Whisper / Gemini
                          │
                          └─► Supabase Postgres (transcripts, summaries, usage logs)
```

The OpenRouter API key never touches your Mac. The app sends requests to our
own Edge Function authenticated with your Supabase JWT; the Edge Function
attaches the OpenRouter key (stored only in Supabase secrets) and forwards
the call. Audio bytes are forwarded once and never written to durable
storage anywhere in this chain.

---

## Change history

| Date       | Change                                        |
|------------|-----------------------------------------------|
| 2026-05-27 | Initial published list.                       |
| 2026-06-02 | Added cross-session search; noted chat messages, embeddings, and extracted entities stored in Supabase. |
| 2026-06-03 | Embeddings are generated in-region by Supabase's built-in `gte-small` model (inside the Edge Function), not sent to any external embedding provider. |
| 2026-06-10 | Added Paddle.com Market Limited as an active subprocessor and Merchant of Record for subscription billing. |

---

Questions? **dbarabashdev@gmail.com**.
