# Subprocessors

_Last updated: 2026-09-01_

_Resend and Pipedream are listed under advance notice. The optional product-update, lifecycle,
and founder-research workflow is not sending today and will not begin earlier
than 30 days after this updated list is published._

A subprocessor is a third party that processes personal data on our behalf
when you use Nod. We use the minimum number of subprocessors required to
deliver the product, and we publish the full list here so you can audit it.

We give 30 days' notice before adding a new subprocessor to this list. To
subscribe to change notifications, email **dmytro@hellonod.app**.

---

## Current subprocessors

| Subprocessor                | Purpose                                  | Data shared                                                       | Location           | Training on your data | DPA / no-train basis |
|-----------------------------|------------------------------------------|-------------------------------------------------------------------|--------------------|-----------------------|----------------------|
| **Supabase, Inc.**          | Auth, Postgres database, Edge Functions, in-region text embeddings (`gte-small`) for cross-session search, first-party acquisition attribution and product analytics | Email, OAuth identity, meeting transcripts, summaries, chat messages, transcript embeddings, extracted entities, usage logs, consented campaign touches, bounded app interaction events, random installation/session IDs, and account attribution | AWS `eu-west-1` (Ireland) | No                    | Supabase DPA         |
| **OpenRouter, Inc.**        | LLM request routing + Whisper transcription (last-resort fallback) | Audio chunks (transient), transcript text, chat messages, query text | Routed via no-train providers | No                    | Zero Data Retention enabled; "may train on request data" routes disabled |
| **Groq, Inc.**              | Whisper (large-v3) speech-to-text — primary transcription provider | Audio chunks (transient — one short WAV per utterance) | USA (Google Cloud) | No | GroqCloud DPA; Services Agreement prohibits training on Inputs/Outputs; no retention by default (transient error/abuse logs ≤ 30 days; ZDR available) |
| **OpenAI** (via Azure OpenAI Service) | Whisper speech-to-text (fallback) | Audio chunks (transient, ~5 s windows)                            | Routed by OpenRouter | No                    | Azure OpenAI no-train commitment |
| **Anthropic PBC** (via AWS Bedrock / Google Vertex AI) | LLM summarisation & chat — primary (Claude Sonnet 4.6, Claude Haiku 4.5 fallback) | Transcript text, system prompt, chat messages | Routed by OpenRouter | No | Bedrock / Vertex AI no-train commitment |
| **Google LLC** (via Google Vertex AI) | LLM summarisation — optional alternative model (Gemini) + a routing host for Claude | Transcript text, system prompt | Routed by OpenRouter | No                    | Vertex AI no-train commitment |
| **Google LLC** (OAuth)      | Authentication (sign-in with Google)     | Your Google email, OpenID profile claims                          | Global             | No                    | Google OAuth ToS     |
| **Apple, Inc.**             | macOS app distribution & code signing    | Crash logs (if you opt-in via System Settings), receipt validation | Global             | No                    | Apple Developer Agreement |
| **Paddle.com Market Limited** | Merchant of Record — subscription billing, payment processing, VAT/sales-tax remittance, invoicing, refunds | Name, email, billing address and country, and payment-method details you enter at checkout; subscription and transaction records | UK; global payment processing | No | Paddle DPA; Paddle acts as Merchant of Record |
| **Vercel Inc.**             | Hosting for the marketing website (`hellonod.app`) + cookieless Web Analytics | Visitor IP (transient — used to derive aggregate page-view/event counts, never stored or exposed), user-agent, page path. No account or meeting data. | USA (global edge) | No | Vercel DPA; Web Analytics is cookieless and does not track across sites |
| **Google LLC** (Analytics and Ads) | Consent-gated website analytics, campaign attribution, and conversion measurement | IP address, browser/device data, sanitised page and event details, Google Analytics client ID, and Google click/campaign identifiers. No meeting content or Nod account identity. | Global | No | Google Ads Data Protection Terms; Google Controller-Controller Data Protection Terms where applicable |

Audio is never stored by any subprocessor — it exists only for the duration
of a single Whisper request and is discarded by the upstream provider as
soon as the transcription completes.

Nod never receives or stores your full card details — those are handled
entirely by Paddle as Merchant of Record.

---

## Notified, not yet active

| Subprocessor | Planned purpose | Data shared | Location | Training on your data | DPA / basis |
|---|---|---|---|---|---|
| **Resend, Inc.** | Delivery of the three optional email topics you can switch on, plus narrow operational referral-status notices | Email address, language, selected topic and consent state, template identifier, and delivery / bounce / complaint / suppression / unsubscribe status. No meeting content. | EU sending region; global delivery | No | Resend DPA and Standard Contractual Clauses |
| **Pipedream, Inc.** | Holding the authorization for tools you connect yourself, and passing our requests to them. Nothing is connected until you connect it, and each connection covers one product. | The access and refresh tokens for the account you authorized — we never receive or store them — plus the content of each request we make on your behalf. For a task filed in a tracker that is the title and description we generated from an action item, and the identifier of the colleague it is assigned to; for a team chat it is the channel name and the members being added; for a calendar it is the events we read back — titles, times, conferencing links and attendee email addresses — and the events you ask us to create, change or cancel; for mail it is the draft you ask us to save — never sent by us — and the messages we read back to answer a question you asked; for files it is the text of the document you asked about; for a wiki, a CRM or an issue tracker it is the note, page, issue or comment you ask us to file. When an administrator connects a tool we also read its member list once — names, addresses and that tool's own identifiers — so that work can be assigned to the right colleague without everyone first having to be invited to Nod. | `api.pipedream.com` | No | Pipedream DPA |

Connecting a tool is the only thing that puts Pipedream between us and it. An account
that connects nothing never reaches them, and disconnecting in the provider's own
settings ends the authorization at the source rather than asking us to forget it.
The point of routing through them is that the token stays theirs to hold: a copy
of your Linear or calendar credential never lands in our database.

Open tracking and click-tracking links are disabled on our sending domain, so we
receive no signal that an email was opened or a link inside it was followed.

## What we do **not** use

- **No third-party analytics SDKs in the app.** The macOS app embeds no
  third-party telemetry SDK —
  no PostHog, Mixpanel, Amplitude, Segment, Google Analytics, or Sentry. The
  marketing website uses consent-gated Vercel Web Analytics, Google Analytics,
  and Google Ads measurement. They never receive meeting content or Nod account
  identity. App product events stay first-party in Supabase and are not sent to
  Google.
- **No third-party fonts or icon CDNs.** The website self-hosts its fonts and
  app icons, so loading a page sends no request — and no visitor IP — to
  Google Fonts, `gstatic`, or any other CDN.
- **No in-product advertising or data sale.** Nod shows no ads and does not
  sell personal data. Google Ads receives measurement data only after website
  analytics consent.
- **No meeting-platform bots.** We do not deploy a bot into Zoom, Meet, or
  Teams — Nod captures audio locally via macOS APIs only.
- **Granola is not a subprocessor.** Nod's "Import from Granola" feature reads
  Granola's local cache file on your Mac to bring your own transcripts in. No
  data is sent **to** Granola, and Granola never processes data on our behalf.
- **Hugging Face is not a subprocessor.** Nod downloads its on-device speaker
  model from a public Hugging Face repository the first time it separates
  speakers, then caches it on disk. The download discloses your IP and app
  version, as any download does; no audio, transcript, or account data is sent,
  and Hugging Face processes nothing on our behalf.
- **Official connector clients are user-selected recipients.** When you
  authorize ChatGPT or Claude, Nod sends the meeting data you request directly
  to that client under a read-only OAuth grant. OpenAI or Anthropic processes
  that data under its own relationship with you, not on Nod's behalf, so this
  connector use does not make either company a Nod subprocessor.

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
own Edge Function authenticated with your Supabase JWT; the Edge Function
attaches the provider key (stored only in Supabase secrets) and forwards
the call. Speech-to-text goes to Groq first, with OpenAI and OpenRouter as
fallbacks; chat and summaries go through OpenRouter. Audio bytes are
forwarded once and never written to durable storage anywhere in this chain.

---

## Change history

| Date       | Change                                        |
|------------|-----------------------------------------------|
| 2026-05-27 | Initial published list.                       |
| 2026-06-02 | Added cross-session search; noted chat messages, embeddings, and extracted entities stored in Supabase. |
| 2026-06-03 | Embeddings are generated in-region by Supabase's built-in `gte-small` model (inside the Edge Function), not sent to any external embedding provider. |
| 2026-06-10 | Added Paddle.com Market Limited as an active subprocessor and Merchant of Record for subscription billing. |
| 2026-06-23 | Added Vercel Inc. (marketing-site hosting + cookieless Web Analytics). Self-hosted website fonts and app icons to stop IP leakage to Google CDNs. |
| 2026-06-24 | Added Groq, Inc. as the primary Whisper speech-to-text provider (audio transient, no retention by default). OpenAI/OpenRouter Whisper are now fallbacks. |
| 2026-06-25 | LLM summaries & chat now default to Anthropic Claude (Sonnet 4.6, Haiku 4.5 fallback), routed via AWS Bedrock / Google Vertex AI (no-train). Google Gemini becomes an optional model rather than the default. No change to data shared or retention. |
| 2026-07-30 | Speaker separation moved to an on-device Core ML model fetched once from a public Hugging Face repository. Noted as an outbound download, not a subprocessor — no audio, transcript, or account data is sent. |
| 2026-08-06 | Documented official ChatGPT and Claude connectors as user-authorized recipients, with read-only OAuth access rather than subprocessors acting for Nod. |
| 2026-08-07 | Added consent-gated Google Analytics and Google Ads measurement, plus first-party campaign-to-account attribution in Supabase. |
| 2026-08-08 | Documented bounded first-party macOS/iOS product interaction events stored in Supabase; no app analytics SDK or Google app telemetry was added. |
| 2026-08-15 | Gave advance notice of Nango for tool connections you make yourself — outbound actions (Linear) and, when it ships, reading your calendar. Nothing is connected until you connect it. |
| 2026-08-14 | Corrected the email-tracking description: click tracking is enabled on our sending domain, not disabled as previously stated. Open tracking remains off. |
| 2026-08-11 | Gave advance notice of Resend for the three separately consented optional email topics and for operational referral-status notices. Nothing is sending under this workflow yet. |
| 2026-08-15 | Disabled click tracking, clarified the separate trial-learning consent and cadence, preserved earlier choices for their original purposes, and restarted the 30-day notice period before any Resend contact sync or send. |
| 2026-08-16 | Extended the advance notice for connected tools to a team chat and to assigning work to a named colleague. When an administrator connects a tool, its member list is read once so colleagues can be named without each being invited to Nod first; matching is by email address only. No new subprocessor: everything still passes through Nango. |
| 2026-08-24 | Replaced Nango with Pipedream, Inc. as the integration provider for tools you connect yourself. Nothing changes about what is shared or why, and no connected tool ever reached production under the previous provider. The 30-day notice period for connected tools restarts from this date. |
| 2026-09-01 | Widened what a connected tool can be asked to do, under the same subprocessor and the same confirmation rule: calendar events can now be changed or cancelled as well as created; an issue can be filed, commented on, closed or reopened; and a mail draft, a CRM note, or a wiki page can be filed on your instruction. Reading widened too: a Drive document's text and a mail message's text can be read back to answer a question you asked. Every change is shown to you and confirmed before it runs; drafts are never sent by Nod. |

---

Questions? **dmytro@hellonod.app**.
