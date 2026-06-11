# Subprocessors

_Last updated: 2026-06-11_

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
| **Paddle.com Market Limited** | Subscription billing & payments as Merchant of Record, VAT/sales-tax remittance, invoicing, customer portal | Your email and Nod user id (to attach the subscription); billing address and payment details you enter at Paddle's checkout — **card data is handled solely by Paddle and never reaches Nod** | United Kingdom / EU (global payment processing) | No | Paddle DPA |

Audio is never stored by any subprocessor — it exists only for the duration
of a single Whisper request and is discarded by the upstream provider as
soon as the transcription completes.

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
| 2026-06-02 | Added cross-session search; noted chat messages, embeddings, and extracted entities stored in Supabase. |
| 2026-06-03 | Embeddings are generated in-region by Supabase's built-in `gte-small` model (inside the Edge Function), not sent to any external embedding provider. |
| 2026-06-11 | Paid tier launched: Paddle.com Market Limited added as active billing subprocessor (Merchant of Record); removed from the planned list. |

---

Questions? **dbarabashdev@gmail.com**.
