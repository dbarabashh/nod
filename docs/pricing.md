# Nod — Pricing

_Last updated: 2026-08-11_

The spec the pricing surfaces are built from. Three of them have to agree, and
each has its own copy: `plans` / `plan_prices` in Supabase (the only enforced
truth), `hellonod.app/pricing` (`nod-landing`, 12 locales), and the in-app
paywall (`PaywallView`). When a number here changes, all three move.

The prices in **Plans** below are the ones in force. This document exists because
the *limits* are derived, and the derivation has to be written down or it gets
re-guessed.

A replacement catalog is under discussion in
[NOD-76](https://linear.app/hellonod/issue/NOD-76) and is **not approved**. It is
implemented behind a switch so it can be validated, and the code being written is
not a decision — see "Replacement catalog under discussion" below.

---

## Plans

| | **Trial** | **Starter** | **Pro** |
|---|---|---|---|
| Price, billed yearly | **$0** for 14 days | **$9 / mo** ($108 / yr) | **$19 / mo** ($228 / yr) |
| Price, billed monthly | — | **$14 / mo** | **$29 / mo** |
| Meeting hours / month | **5** | **8** | **Unlimited** (fair use) |
| Devices | 1 | 1 | 3 |
| Card required to start | no | — | — |

Prices are **tax-inclusive**: the figure above is what the customer is charged,
and Paddle remits VAT/GST out of it. `terms.md` § 7 says so; it used to say the
opposite.

There is no overage and no usage credits. Both were built once and deleted
(`df98ba8 remove overage feature`); the landing advertised `$0.60 / hr` for
weeks after the code stopped being able to charge it.

## Replacement catalog under discussion — NOT approved

Implemented, dark, and awaiting an explicit founder pricing decision. Nothing
below is live: the rows exist in `plan_prices` with
`available_for_new_checkout = false`, so no client can offer them, and the app
keeps selling the catalog above until `cutover_pricing_catalog(…)` is called with
real per-branch Paddle IDs.

| | **Starter** | **Pro** |
|---|---|---|
| Proposed monthly | $15 / mo | $24 / mo |
| Proposed yearly | $144 / yr ($12 / mo) | $240 / yr ($20 / mo) |
| Change vs live | $14 → $15 monthly; $108 → $144 yearly | $29 → $24 monthly; $228 → $240 yearly |

This is not an across-the-board increase, and the annual discount depth changes
materially: the live page advertises roughly 35%, the proposal is 20% on Starter
and 16.7% on Pro. The paywall now computes that badge from the catalog instead of
hardcoding it, so it cannot advertise a discount the prices do not give.

Alongside it: a **Starter top-up** of +5 hours for $12 — explicit, repeatable,
never automatic, expires with the billing month, no rollover, and no Pro
equivalent. Existing subscriptions keep their current Paddle price unless the
subscriber changes plan or cycle themselves; the webhook still resolves
superseded price IDs so a renewal never silently reprices anyone.

The open questions (is $24 the right conversion move, is $108 → $144 too abrupt,
does the live "AI coworker" positioning justify moving now) belong to NOD-76 and
NOD-66, not to this file.

## Features

Enforced means a line of code checks it. Everything else is a marketing row that
happens to be true because no plan restricts it.

| | Trial | Starter | Pro | Enforced where |
|---|---|---|---|---|
| Records you + the other side | ✅ | ✅ | ✅ | — |
| Live transcription, 14 languages | ✅ | ✅ | ✅ | — |
| Summary, title, action items | ✅ | ✅ | ✅ | `action_items` flag, client UI only |
| Ask Nod about one meeting | ✅ | ✅ | ✅ | `llm-proxy`, `ask_single_meeting` |
| Unlimited history, folders, search | ✅ | ✅ | ✅ | — |
| Audio is never stored | ✅ | ✅ | ✅ | `WhisperTranscriber` discards chunks |
| Ask Nod live during a meeting | ✅ | — | ✅ | client only (`ask_live`) — no server gate |
| Ask across all meetings | ✅ | — | ✅ | `llm-proxy`, `ask_across_meetings` |
| Folder-scoped questions | ✅ | — | ✅ | `llm-proxy`, `label_scoping` |
| **Screen context (ambient)** | ✅ | — | ✅ | `screen_observations` RLS + client |
| Early access + priority support | ✅ | — | ✅ | operational, not code |
| Speaker labels | — | — | — | **not shipped** — see below |

`plans.features` is the mapping; the client's `Feature` enum only knows the key
names. Re-pricing which plan unlocks what is a data change, not a release.

## Where the limits come from

Measured over the 30 days to 2026-08-02, in prod:

| | |
|---|---|
| STT | **$0.163** per wall-hour |
| LLM | **$0.0279** per call, 4.83 calls per meeting |
| Embeddings | **$0.00** (model is local to the edge function) |
| Blended, median user | **$0.406 / hour** |
| Blended, worst observed profile | **$0.574 / hour** |

The cost driver is not hours, it is **short meetings plus heavy Ask Nod**: every
meeting pays a fixed summary-and-title price regardless of length, so the same
15 hours cost between $3.30 and $8.40 depending on how they are spent. The floor
is 3.0 LLM calls per meeting; everything above that is discretionary.

Revenue is not the sticker price. Prices are tax-inclusive and Paddle is
Merchant of Record, so **~79% of a yearly price reaches us**:

| | Charged | − VAT (20%) | − Paddle (5% + $0.50) | **Net / month** |
|---|---|---|---|---|
| Starter, yearly | $108 / yr | $90.00 | $85.00 | **$7.08** |
| Starter, monthly | $14 | $11.67 | $10.58 | **$10.58** |
| Pro, yearly | $228 / yr | $190.00 | $180.00 | **$15.00** |
| Pro, monthly | $29 | $24.17 | $22.46 | **$22.46** |

The yearly buyer is the binding case everywhere below — the annual discount and
the VAT haircut stack.

**Starter's 8 hours is a real ceiling.** `price > limit × worst-profile cost`:
$7.08 × 65% ÷ $0.574 = 8.0. At 8 hours the worst profile costs $4.59 and leaves
35%; the median profile costs $3.25 and leaves 54%.

**Pro's "unlimited" is a bounded promise, not an uncapped one.**
`plans.pro.limits.hours_per_month` is **40** — the fair-use threshold from
`terms.md` § 7, never displayed. It is 2.6× the largest month ever recorded on
any plan (15.4 h, a trial) and ~6× the p90 paying user; the largest Pro month to
date is 6.2 h. Someone who reached it would cost ~$23 against $15 of revenue, so
the claim costs at most ~$8 a month per outlier — against an unbounded liability
if no ceiling existed. Break-even on Pro is 26 hours for the worst profile and
37 for the median.

`plans.hours_are_unlimited` decides whether a surface prints the number.
`hours_per_month` stays the truth for metering. A sentinel value was rejected:
the reader that forgot the convention would print "40 meeting hours / month"
beside a page promising unlimited.

## Existing subscribers keep what they bought

Lowering Starter from 15 to 8 and re-framing Pro would have downgraded people
mid-subscription, so migration `20260802100544` pins each already-active
subscription's old ceiling into `subscriptions.limit_overrides` **before**
touching `plans` — copying whatever the plan grants at that moment rather than a
hardcoded 15/50, so it stays correct on any branch.

The pin expires when the plan does: `apply_paddle_subscription` drops
`limit_overrides->'hours_per_month'` whenever `plan` changes
(`20260802103325`). Without that, a grandfathered Starter upgrading to Pro
resolved to a *lower* cap than Pro grants, and a grandfathered Pro downgrading
kept 50 hours on the cheaper plan forever.

Trials are deliberately not grandfathered: the page has always said 5 hours, so
the cap makes a promise true rather than breaking one.

## Billing rules

- **Paid from day one.** No permanent free tier — every transcription costs real
  compute. The 14-day trial is the risk-free path instead.
- **7-day money-back guarantee**, plus the EU/UK 14-day cooling-off period.
  Detail in `refund.md`.
- **Yearly is the best value** for the customer and the most fee-efficient for
  us: one transaction a year amortises Paddle's $0.50 per-transaction fee.
- **Regional (PPP) pricing** is configured per-country in the Paddle dashboard,
  not in this repo. One subscriber is on a manually granted 80% discount.
- **No overage, ever.** Fixed subscription. `terms.md` § 7 promises we do not
  meter, do not bill overage, and do not cut off mid-meeting.

## Not shipped yet

Each of these is a claim some surface already makes, or a control the numbers
above assume exists. None of them is live.

- [ ] **Hour enforcement is implemented but not switched on.** The app asks for a
      server lease before capture (`start_meeting_lease`, which checks
      `can_start_meeting` atomically) and every transcription chunk presents that
      recording's ID. A new meeting is refused when the allowance is gone; a
      meeting already running is never cut off, and the lease is renewed by use so
      a crash frees the slot in minutes. Chunk-level enforcement stays off until
      `activate_meeting_lease_enforcement(<build>)` raises
      `app_config.meeting_lease_required_build` — which also raises
      `minimum_build`, so it forces every older build to update and must follow a
      release, never precede one.
- [ ] **No fair-use alerting.** `terms.md` § 7 promises we email a Pro user
      *before* acting on extraordinary usage, which requires knowing they are
      approaching 40 hours in their billing period. Nothing computes that today —
      see the founder-dashboard gap below.
- [ ] **Speaker labels are advertised but not released.** `hellonod.app/pricing`
      carries the row in `en` and `uk`; diarization lives on branch
      `diarization-phase1`, and 1 meeting out of 237 has `speaker_names`. Either
      ship it or pull the row.
- [ ] **`ask_live` has no server gate.** `llm-proxy` feature-checks only the
      three `search` scopes; the in-meeting Ask box is gated client-side only.
- [ ] **`label_scoping` has no client gate.** The proxy enforces it, so a Starter
      user sees the folder-scope affordance and gets a 403.

## Founder-dashboard gap

Per-user hours **within the current billing period, against the plan's limit,
do not exist anywhere**. `founder_users_enriched` returns
`minutes_transcribed` and `cost_usd` for a user's **entire lifetime**, with no
window and no comparison to `hours_limit`; the Users table renders it as
"Transcribed". `founder_usage_breakdown` has `minutes`, but aggregated by `kind`
across all users. (`minutes_transcribed_30d` exists in the dashboard's types,
but it belongs to `founder_overview` — a product-wide figure, not per-user.)

The window to reuse is `resolve_entitlement`'s, which is not a calendar month:
for an annual plan it walks the term start forward month by month
(`20260730081521_monthly_usage_window_for_annual_plans`), so a naïve
`date_trunc('month')` reports the wrong period for exactly the yearly
subscribers the fair-use ceiling is about.

## Related

| Topic | Where |
|---|---|
| Fair use, tax treatment, refunds | `docs/policies/terms.md` § 7 |
| Which policy a pricing change touches | `docs/policy-bindings.md` |
| Landing pricing table, 12 locales | `../nod-landing/src/locales/*.ts` |
| Entitlement resolution | `supabase/migrations/*monthly_usage_window*`, `Nod/Core/Backend/EntitlementService.swift` |
