# App Store privacy disclosure

_Last updated: 2026-08-08_

This document is the source of truth for App Store Connect privacy answers for
Nod Mobile. It describes the shipped first-party analytics contract and must be
reviewed whenever iOS telemetry fields, consent, retention, or recipients
change.

## Data type declarations

| App Store category | Collected | Linked to identity | Tracking | Purpose |
|---|---|---|---|---|
| Contact Info — Email Address | Yes, after account authentication | Yes | No | App Functionality |
| User Content — Audio Data | Transient processing only; not retained | Yes during the request | No | App Functionality |
| User Content — Other User Content | Yes: transcripts, summaries, saved Ask messages | Yes | No | App Functionality |
| Identifiers — User ID | Yes | Yes | No | App Functionality, Analytics |
| Usage Data — Product Interaction | Yes, only after iOS analytics consent | Claimed after authentication; anonymous before it | No | Analytics |
| Diagnostics — Other Diagnostic Data | Yes: bounded capture stage and reason categories, without raw errors | Yes after authentication | No | Analytics, App Functionality |
| Purchases | Subscription state is read from Nod's server; no iOS purchase flow exists | Yes | No | App Functionality |

## Product interaction boundary

The iOS app sends only allowlisted event names plus bounded categories for
platform, app version, session kind, entry point, stage, reason code, surface,
content type, AI feature, outcome, plan, and billing. It does not send meeting
content, transcript or summary text, questions, answers, titles, email,
clipboard contents, share tokens, advertising identifiers, precise location,
contacts, photos, or arbitrary errors.

The first onboarding screen provides Allow and Don't Allow. Events before the
choice remain only on-device. Decline clears them and produces no telemetry
request. Settings can revoke consent and clear the queue. No analytics SDK is
embedded, data is not used for cross-company tracking, and app activity is not
sent to Google Analytics or Google Ads.

Unclaimed anonymous onboarding rows expire after 30 days. Claimed onboarding
and authenticated product events expire after 24 months or immediately on
account deletion.
