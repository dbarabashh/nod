# Cookie Policy

_Last updated: 2026-09-10_

This policy explains the browser storage and measurement technologies used on
`hellonod.app`. The Nod macOS and iOS apps do not use cookies.

## Default state

Analytics and advertising storage are denied by default. Google Tag Manager,
Google Analytics 4, Google Ads measurement, and Vercel Web Analytics load only
after you choose **Allow analytics**. Declining does not affect the site,
download, sign-in, trial, or paid service.

## Browser storage we control

| Name | Type | Purpose | Retention |
|---|---|---|---|
| `nod_analytics_consent_v1` | Local storage | Remembers whether you accepted or declined optional analytics. | Until you clear site data or change the setting. |
| `nod_visitor_id_v1` | Local storage | Random first-party ID used to join consented website events and, if you sign in from Nod, attribute a trial to a campaign. | Until you clear site data or withdraw consent. Server-side events are deleted on withdrawal or after 400 days. |
| `nod_session_id_v1` | Session storage | Random ID used to count a browser session without storing the page URL or identity. | Until the browser tab or session ends, or you withdraw consent. |
| `nod_campaign_v1` | Local storage | Keeps the most recent UTM and Google click campaign details for attribution during the visit and download/sign-in flow. | 90 days, until replaced, until you clear site data, or until you withdraw consent. Server-side events are deleted on withdrawal or after 400 days. |
| `nod_hero_variant_v1` | Local storage | Records which version of the homepage headline you were shown, so a page test shows you the same version on later visits rather than changing under you. Holds only the letter `A` or `B` — no identifier and nothing about you. | Until you clear site data or withdraw consent. |
| `nod_booking_confirmation_event_v1` | Session storage | Reuses one random event ID so reloading a marked booking confirmation redirect cannot create duplicate first-party confirmation rows. It records only redirect arrival, not a verified booking. | Until the browser tab or session ends. |

Supabase Auth may use browser storage on connector authorization pages to keep
the security state required for sign-in and OAuth grants. Those private pages
do not load marketing analytics.

Token-bearing invite pages never load Google, GTM, or Vercel analytics. After
consent, clicking Open or Download sends only a first-party Supabase event with
the path forced to `/invite`; invite tokens, query values, referrers, campaign
fields, and Google identifiers are omitted. The marked booking-confirmation
page likewise sends only a first-party, explicitly unverified redirect event.

## Google Analytics and Google Ads

After consent, Google may set cookies such as `_ga` and `_ga_<container>` to
distinguish browser instances and sessions, and advertising measurement cookies
associated with a Google ad click. Exact names can vary as Google changes its
services. We configure advertising personalisation as denied and use the data
only for aggregate analytics, attribution, and conversion measurement.

We send sanitised page paths and event details. Invite tokens, OAuth values,
checkout transaction parameters, meeting content, email, name, and Nod user ID
are excluded.

## Change or withdraw consent

Use **Privacy settings** in the footer on any public page. A decline immediately
stops optional measurement, deletes the first-party acquisition touches tied to
the random visitor ID, and prevents Nod from loading Google or Vercel analytics
on later page loads. You can also clear existing cookies and local storage in
your browser settings.

Questions or privacy requests: **dmytro@hellonod.app**.
