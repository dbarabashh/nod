# Privacy Policy

_Last updated: 2026-06-24_

> **Nod is in private beta.** It is built and operated by an individual
> developer, not a registered company. This policy describes the data
> practices that already exist in the product today — every claim is tied
> to code you can inspect.

This Privacy Policy describes how Nod ("Nod", "we", "us", "I") collects, uses,
stores, and shares personal data when you use the Nod macOS application
and the related services hosted at `hellonod.app`. It applies to all users,
worldwide.

If you have questions about this policy or your data, contact
**dbarabashdev@gmail.com**.

---

## 1. Who we are (data controller)

Nod is operated by **Dima Barabash**, an individual developer. There is no
incorporated company behind Nod — that's an honest disclosure, not a gap
we're hiding.

For the purposes of the EU/UK GDPR, the data controller is Dima Barabash
personally. The contact point is **dbarabashdev@gmail.com**.

Paid subscriptions are sold through **Paddle.com Market Limited**, which
acts as our Merchant of Record. Paddle is an independent controller of the
billing and tax data it collects to process your payment — see Paddle's own
privacy notice for how it handles that data. Nod never receives or stores
your full card details.

## 2. What Nod is

Nod is a macOS app that records meetings playing through your Mac's
speakers and microphone, transcribes them via Whisper, and produces an
AI-generated summary using a large language model. It runs as a small
floating panel and never records without you pressing record.

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
| Meeting metadata (start/end time, title, language, session **kind**: meeting / voice note / media) | To list and organise your sessions | Contract (Art. 6(1)(b)) |
| Transcript **embeddings** (vector + chunk text, in `session_embeddings`) | To let you ask questions across your past sessions ("Ask Nod") | Contract (Art. 6(1)(b)) |
| **Chat messages** with the per-session assistant (`chat_messages`) | To answer your questions about a session and keep the thread | Contract (Art. 6(1)(b)) |
| **Entities** (people / projects / topics extracted from a session) | To link related sessions and power scoped search | Contract (Art. 6(1)(b)) |
| Your optional **profile** (name, role, current focus) | To give the assistant context about you | Contract (Art. 6(1)(b)); you may leave it blank or clear it anytime |

The embeddings, chat messages, and entities are derived from transcript
content you already chose to record; they are stored in the same
Supabase database, in the same `eu-west-1` region, under the same per-user
Row-Level Security. The cross-session "Ask Nod" conversation is **not**
persisted.

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

### 3.5 Device binding

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

### 3.6 Subscription and billing state

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

### 3.7 What we do **not** collect

- The macOS app embeds **no** analytics SDKs (PostHog, Mixpanel, Amplitude,
  Segment, Google Analytics, Sentry, etc.). The marketing website uses only
  **Vercel Web Analytics** — cookieless, aggregate page-view and download-click
  counts, no cross-site tracking (see the Subprocessors page).
- We do **not** track you across the web or use advertising cookies.
- We do **not** read your calendar, email, or other Google services.
- We do **not** collect your contacts or address book.
- We do **not** sell your personal data to anyone, ever.

### 3.8 Importing from other apps (Granola)

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
  OpenAI via Azure, Google Cloud / Vertex, Google OAuth, Apple, and Paddle
  for billing).
- We're legally compelled (court order, lawful subpoena). We will notify
  you unless prohibited by law.
- You explicitly ask us to (for example, exporting your data to another
  service at your request).
- As part of a business transfer (merger, acquisition, asset sale). We
  will notify you with at least 30 days' notice and you can delete your
  data before any transfer.

---

## 6. International transfers

Your account, transcripts, summaries, and usage metadata are stored in the
European Union (AWS `eu-west-1`, Ireland).

Some subprocessors operate globally and may process data outside the EU:

- **Groq** (speech-to-text), **OpenRouter**, **OpenAI/Azure**, and
  **Google/Vertex** may route requests to US-based infrastructure.
  Transfers rely on the EU
  Commission's adequacy decision for the US (EU–US Data Privacy
  Framework) where applicable, or on Standard Contractual Clauses
  (SCCs) otherwise.
- **Google OAuth** and **Apple** are global services and may process
  authentication / app-distribution data outside the EU under SCCs.

We can provide our SCCs and transfer impact assessments on request to
**dbarabashdev@gmail.com**.

---

## 7. How long we keep your data

| Data                                 | Retention                                                            |
|--------------------------------------|----------------------------------------------------------------------|
| Account (auth profile)               | Until you delete your account.                                       |
| Device bindings (`user_devices`)     | Until the device signs out, is evicted by the inactivity timeout, or you delete your account (cascade). |
| Meetings (active)                    | Until you delete them.                                               |
| Meetings (in trash)                  | 30 days. A nightly Postgres job permanently deletes anything older. |
| Meeting transcripts                  | Same as the parent meeting (cascade delete).                         |
| Transcript embeddings, session chats, entity links | Same as the parent meeting (cascade delete). Extracted entities themselves are per-user and removed on account deletion. |
| Consent acknowledgements             | 6 years from the date of acknowledgement (legal-defence window).     |
| Usage metadata                       | 24 months, then aggregated and anonymised.                           |
| Encrypted database backups           | 7 days rolling.                                                      |
| Server logs (OpenRouter calls, etc.) | 30 days.                                                             |

When you delete your account from **Settings → Privacy**, we erase your
auth profile, meetings (active and trashed), transcripts, summaries, chats,
entities, labels, device bindings, usage rows, and subscription row
immediately — the deletion cascades the moment you confirm it. We retain
your consent acknowledgement rows for the legal-defence window above; these
become orphaned (`user_id` set to NULL) and are no longer linked to you in
any externally-resolvable way.

---

## 8. Your rights

Under the EU/UK GDPR (and equivalents in California, Brazil, Canada, etc.)
you have the following rights. To exercise any of them, email
**dbarabashdev@gmail.com**. We respond within 30 days.

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
  of residence. Nod is currently operated by an individual developer
  rather than a registered company, so there is no designated lead
  supervisory authority — your home-country authority is the right
  contact.

We do **not** make automated decisions with legal or similarly significant
effects about you.

---

## 9. Security

Encryption in transit (TLS 1.2+, default TLS 1.3, lower protocols
rejected), encryption at rest (AES-256), Row-Level Security on every
table, secrets isolated server-side. Detail in our [Security page](./security.md).

If you discover a vulnerability, please email **dbarabashdev@gmail.com**.
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
website). Our marketing site at `hellonod.app` is a static site that sets
**no cookies** — it uses Vercel Web Analytics, which is cookieless and stores
no cross-site identifier, and self-hosts its fonts and app icons so visiting a
page sends no request (and no IP) to any third-party CDN. We use no advertising
or third-party analytics cookies. If this changes we will publish a separate
Cookie Policy.

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

- Privacy questions and rights requests: **dbarabashdev@gmail.com**
- Security: **dbarabashdev@gmail.com**
- Everything else: **dbarabashdev@gmail.com**

---

> **Operator's note:** This document is a working draft tied to Nod's
> actual data flows as of the date above. It must be reviewed by a
> qualified privacy lawyer before publication, in particular sections 1
> (controller entity), 6 (transfer mechanisms), 8 (supervisory
> authority), and the retention windows in section 7.
