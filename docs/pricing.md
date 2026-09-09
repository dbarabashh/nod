# Nod — Pricing

_Last updated: 2026-09-06_

The spec the pricing surfaces are built from. Three of them have to agree, and
each has its own copy: `plans` / `plan_prices` in Supabase (the only enforced
truth), `hellonod.app/pricing` (`nod-landing`, 12 locales), and the in-app
paywall (`PaywallView`). When a number here changes, all three move.

The prices in **Plans** below are the approved ones. This document exists because
the *limits* are derived, and the derivation has to be written down or it gets
re-guessed.

The NOD-76 replacement catalog was **approved on 2026-08-12** and cut over on
prod the same day, so the numbers below are what a new customer is charged.
Existing subscribers keep the price they bought at — see "Cutover status".

---

## Plans

| | **Trial** | **Starter** | **Pro** |
|---|---|---|---|
| Price, billed yearly | **$0** for 14 days | **$12 / mo** ($144 / yr) | **$20 / mo** ($240 / yr) |
| Price, billed monthly | — | **$15 / mo** | **$24 / mo** |
| Meeting hours / month | **5** | **8** | **Unlimited** (fair use) |
| Devices | 1 | 1 | 3 |
| Card required to start | no | — | — |

Prices are **tax-inclusive**: the figure above is what the customer is charged,
and Paddle remits VAT/GST out of it. `terms.md` § 7 says so; it used to say the
opposite.

There is no automatic overage: nothing is ever charged without a checkout.
Per-hour overage was built once and deleted (`df98ba8 remove overage feature`);
the landing advertised `$0.60 / hr` for weeks after the code stopped being able
to charge it. What does exist is explicit, one-time **packs** bought for the
current period (hours; and, on the `integrations` branch, integration
credits — see "Built on `integrations`, sandbox only").

## Cutover status — live since 2026-08-12

Every surface now carries the prices above. The cutover ran on prod that day,
after the NOD-76 migrations landed and the live Paddle prices were created:

| Surface | Carries | State |
|---|---|---|
| `hellonod.app/pricing` | $15 / $24 (new) | moved 2026-08-12 |
| `docs/pricing.md` (this file) | new | moved |
| Paddle **sandbox** catalog | new | moved |
| Paddle **live** catalog | new | **moved 2026-08-12** |
| Prod `plan_prices` | new | **moved 2026-08-12** |
| In-app paywall | reads `plan_prices` | follows prod — new on every build |

The paywall needed no release to follow: the `plan_prices` RLS policy for
`authenticated` is `active AND available_for_new_checkout`, so the superseded
rows stop being readable the moment the cutover flips them, and builds that
predate the new catalog render the new prices too.

### Live catalog

| SKU | Live price id |
|---|---|
| `starter_monthly_usd_15` | `pri_01kzv9ye8z5hc9d8ap0d5kcr91` |
| `starter_yearly_usd_144` | `pri_01kzv9yeetzmhetcnjtea3tby5` |
| `pro_monthly_usd_24` | `pri_01kzv9yem47q6qhqytkx2k61qr` |
| `pro_yearly_usd_240` | `pri_01kzv9yesgja1edh4d8w0x1f1e` |
| `starter_5h_usd_12` | `pri_01kzv9yeyyrqtmwsz46hrcypsr` |

The three marketing discounts on live (`Discount for friends` 40%,
`Friendly discount` 15%, `Nod Pro monthly - 1 month free` 100%) are still
restricted to the superseded price ids, so they no longer apply to a new
checkout. The two referral discounts are unrestricted and follow the catalog.

### Lifecycle win-back offer — built, not released

An account that receives an eligible expired-trial or canceled-subscription
email can claim **15% off the first monthly Starter or Pro billing period**.
The claim expires 14 days after issue, is bound to that account and email
campaign, and cannot be combined with a referral. Checkout creates a
non-recurring Paddle transaction discount restricted to the selected price;
there is no public coupon code or reusable catalog discount.

The campaign rollout modes and the communications-v2 policy gate both start
off. This offer therefore cannot reach customers merely because the code and
templates exist.

### Nobody already paying gets repriced

This is the part that must not be broken by the cutover, and it is already built
two ways:

- **Paddle never reprices an existing subscription** because the catalog changed.
  A subscription is bound to the price ID it was created with, and renewals bill
  that ID. We only have to refrain from calling an update on it.
- **We keep resolving the superseded ID.** `cutover_pricing_catalog` leaves every
  old row `active` and only flips `available_for_new_checkout = false`, so it
  drops out of the storefront without leaving the mapping. The webhook's lookup
  is `select plan from plan_prices where paddle_price_id = p_price_id` — no
  storefront filter — so a renewal on the $29 Pro price still resolves to `pro`.
  If an ID were ever missing entirely, `apply_paddle_subscription` falls back to
  the plan already on the row rather than dropping the subscriber.

The one-way valve is `create-checkout`, which refuses any price that is not
`active` **and** `available_for_new_checkout`, and refuses `pri_REPLACE_*`
outright. So the new prices reach new purchases only, and existing subscribers
move only if they change plan or cycle themselves.

Change vs the old catalog: Starter $14 → $15 monthly and $108 → $144 yearly;
Pro $29 → $24 monthly and $228 → $240 yearly. Not an across-the-board increase —
Pro's monthly price drops while its annual rises.

The annual discount depth changes materially: the old page advertised roughly
35%, the new prices give 20% on Starter and 16.7% on Pro. The landing copy now
says ~20%, and the paywall computes the badge from the catalog rather than
hardcoding it, so neither can advertise a discount the prices do not give.

Alongside it: a **Starter top-up** of +5 hours for $12 — explicit, repeatable,
never automatic, expires with the billing month, no rollover, and no Pro
equivalent. It is not on the landing page yet.

## Features

Enforced means a line of code checks it. Everything else is a marketing row that
happens to be true because no plan restricts it.

| | Trial | Starter | Pro | Enforced where |
|---|---|---|---|---|
| Records you + the other side | ✅ | ✅ | ✅ | — |
| Live transcription, 35 languages | ✅ | ✅ | ✅ | — |
| Summary, title, action items | ✅ | ✅ | ✅ | `action_items` flag, client UI only |
| Ask Nod about one meeting | ✅ | ✅ | ✅ | `llm-proxy`, `ask_single_meeting` |
| Unlimited history, folders, search | ✅ | ✅ | ✅ | — |
| Audio is never stored | ✅ | ✅ | ✅ | `WhisperTranscriber` discards chunks |
| Ask Nod live during a meeting | ✅ | — | ✅ | client only (`ask_live`) — no server gate |
| Ask across all meetings | ✅ | — | ✅ | `llm-proxy`, `ask_across_meetings` |
| Folder-scoped questions | ✅ | — | ✅ | `llm-proxy`, `label_scoping` |
| **Screen context (ambient)** | ✅ | — | ✅ | `screen_observations` RLS + client |
| Early access + priority support | ✅ | — | ✅ | operational, not code |
| Speaker labels | ✅ | ✅ | ✅ | `SessionKind.supportsDiarization`, on device |

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
| Starter, yearly | $144 / yr | $120.00 | $113.50 | **$9.46** |
| Starter, monthly | $15 | $12.50 | $11.38 | **$11.38** |
| Pro, yearly | $240 / yr | $200.00 | $189.50 | **$15.79** |
| Pro, monthly | $24 | $20.00 | $18.50 | **$18.50** |

The yearly buyer is the binding case everywhere below — the annual discount and
the VAT haircut stack.

**Starter's 8 hours is a real ceiling, with more room than it used to have.**
`price > limit × worst-profile cost`: $9.46 × 65% ÷ $0.574 = 10.7, so 8 hours now
sits under what the price would carry rather than exactly on it. At 8 hours the
worst profile costs $4.59 and leaves 51%; the median profile costs $3.25 and
leaves 66%. The cap was derived at $108 / yr, where the same arithmetic gave
exactly 8.0 — it was not re-derived upward on the new price, because the ceiling
also has to keep the top-up worth buying.

**Pro's "unlimited" is a bounded promise, not an uncapped one.**
`plans.pro.limits.hours_per_month` is **40** — the fair-use threshold from
`terms.md` § 7, never displayed. It is 2.6× the largest month ever recorded on
any plan (15.4 h, a trial) and ~6× the p90 paying user; the largest Pro month to
date is 6.2 h. Someone who reached it would cost ~$23 against $15.79 of revenue,
so the claim costs at most ~$7 a month per outlier — against an unbounded
liability if no ceiling existed. Break-even on Pro is 28 hours for the worst
profile and 39 for the median.

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

## Built on `integrations`, sandbox only — NOD-138

Everything in this section is applied to the sandbox branch
(`zdpvmwqauczsfwlgflas`) and dark on prod. It is the proposal in NOD-138 made
real so it can be measured before it is approved; the prod catalogue above is
untouched. Source: `supabase/migrations/20260905203754` … `20260906130516`.

| | **Trial** | **Starter** | **Pro** | **Teams** (per seat, min 3) |
|---|---|---|---|---|
| Price, billed yearly | $0 for 14 days | $12 / mo | **$24 / mo** ($288 / yr) | **$32 / mo** per seat |
| Price, billed monthly | — | $15 / mo | **$29 / mo** | **$39 / mo** per seat |
| Meeting hours / month | 5 | 8 | **20**, metered | 25 × seats, pooled |
| Integration credits / month | 100 | 100 | **500** | 500 × seats, pooled |
| Integrations | core | core (Google Calendar, Notion, Google Drive) | all | all |
| Hour pack | — | 5 h · $12 | 10 h · $29 | — |
| Automation Pack | — | 500 credits · $10 | 500 credits · $10 | 500 credits · $10, bought by an owner/admin for the workspace |

- **Pro is metered at 20 h**, no longer "unlimited with fair use". Every
  subscriber who was on Pro when the change landed keeps what they were sold:
  `limit_overrides.hours_per_month = 40` and, where the row said so,
  `subscriptions.hours_are_unlimited`, both cleared only by a plan change.
  Prod still carries the `unlimited` promise and has not been pinned — that
  decision is open.
- **An integration credit is one metered call** to a connected product through
  the broker. A *read the chat makes* is metered; a write (filing a ticket,
  posting a message, appending notes, a draft, an invite) is free; the reads
  the app makes for its own screens (ticket-status mirror, form pickers, the
  free-slot check) are throttled instead and stay outside the pool. The
  app's own calendar sync is throttled (30-minute floor on open) and never
  metered; asking the chat to list events is a read like any other.
  `integration-action` refuses with `integration_credits_exhausted` at zero and
  the model answers from what it already knows; nothing is charged.
- **Pools are per payer.** A person's pool is `plans.limits.integration_credits_per_month`;
  a workspace's is that × seats, spent by `usage_events.org_id`-stamped rows.
  `resolve_entitlement` reports `integration_credits_included/used/remaining`
  and `can_run_integration_action` beside the hours.
- **Packs are explicit purchases for the current period**, minted through
  `create_topup_checkout_intent` and fulfilled by `apply_topup_purchase`. A
  workspace pack is bought from Organization → Billing by an owner or admin,
  billed to the workspace's Paddle customer, and lands in `usage_topups.org_id`.
  A refund gives back only what was unused, in the unit the pack granted.
- **Surfaces**: the credit pool sits first on Settings → Integrations, under
  "This period" on Subscription, and on Organization → Billing, each with the
  pack beside the count and a plain sentence about what happens at zero. When
  a read is refused mid-conversation, the chat shows `ChatCreditsNotice` under
  the answer — the refill date and the pack for whoever may buy it, or "ask an
  owner or admin" — and the notch's live lookup says "credits are used up"
  instead of blaming the product.
- Paddle **sandbox** prices exist for every row above; live prices do not.
  The policies (`terms.md` § 7, `refund.md` § 6, `privacy.md` § 3.4/7,
  `security.md`, `subprocessors.md`) carry this catalogue as **advance notice**
  since 2026-09-06, and the landing's pricing page describes it on the
  `integrations` branch; neither is live until the cutover.

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
- [ ] **Speaker *names* rarely resolve.** Clustering itself shipped in `v12.11.0`
      (`36934d0 move diarization to speakerkit`) and runs on device for any
      `SessionKind.supportsDiarization`, so the advertised row is true — the
      transcript carries `[Them · Speaker N]`. Putting a real name to a cluster
      is the weak half: it needs a roster, and 1 prod meeting out of 313 has
      `speaker_names`.
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
