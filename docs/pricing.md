# Nod — Pricing

_Last updated: 2026-06-08_

> **Status:** proposed model for the paid launch (private beta today). Source of
> truth for tiers, prices, and the billing rules behind them. Numbers in the
> unit-economics section are estimates — replace the token-cost figure with real
> data from `usage_events.cost_usd` before committing to public prices.

> **No free plan. No ads. No training on your data.** You pay, we stay private —
> and we never touch your audio.

## Tiers

| | **Starter** | **Pro** · _Most popular_ |
|---|---|---|
| | _Your AI notetaker, fully unlocked_ | _For people who live in meetings_ |
| **Price** | **$12/mo** · or **$8/mo** billed yearly _(save 33%)_ | **$29/mo** · or **$20/mo** billed yearly _(save 31%)_ |
| **Meeting hours** | **8 hrs / month** | **40 hrs / month** |
| Need more? | **+5 hrs for $5** | **+10 hrs for $8** |
| Records you **+ the other side** (Zoom, Meet, Teams, calls) | ✅ | ✅ |
| Live transcription, summaries & action items | ✅ | ✅ |
| **Ask Nod** about any meeting | ✅ | ✅ |
| Multilingual + auto-detect | ✅ | ✅ |
| Unlimited history, labels & search | ✅ | ✅ |
| Private by design — **audio is never stored** | ✅ | ✅ |
| **Ask Nod across all meetings** (your knowledge base) | — | ✅ |
| Auto-linking of people, projects & topics | — | ✅ |
| Priority transcription + top-tier summary models | — | ✅ |
| **Devices** | 1 | **Up to 3** |
| Early access + priority support | — | ✅ |

_Billed via our Merchant of Record — taxes included. **7-day money-back
guarantee**, cancel anytime. Yearly saves you ~4 months._

> 🔥 **Founding members:** first 500 sign-ups lock **Starter $8/mo · Pro
> $19/mo — forever.**

## Billing rules

- **Charge on day 1. No free tier.** Every transcription burns tokens (real
  cost), so a standing free cohort is a standing loss.
- **7-day money-back guarantee** — lets people try risk-free without a permanent
  free cohort. Refunds are handled by the Merchant of Record.
- **Yearly is the default-selected option** — the discount plus a single
  transaction per year (instead of 12) cuts payment fees and improves retention.
- **At the hour cap: overage, not a hard stop.** Users keep recording and buy an
  hour pack; this covers the marginal token cost instead of blocking (and
  churning) the user.
- **Founder lock** — the first 500 sign-ups keep their price forever: urgency +
  a fast first cohort of paying users and references.

## Payment provider

Merchant-of-Record model (Polar-style): **5% + $0.50 per checkout
transaction**. The MoR handles cross-border sales tax/VAT, fraud, and
chargebacks — no separate tax setup, no monthly platform fee.

Implications baked into the prices above:

- The flat **$0.50/transaction** makes cheap **monthly** plans bleed, so nothing
  is priced below ~$8/mo-equivalent.
- **Annual billing** drops the effective fee from ~6–8% (monthly) to ~5% (one
  transaction/year) — hence the aggressive annual discount.

## Unit economics (after ALL costs)

Cost lines:

- **Payment commission** — 5% + $0.50/transaction.
- **COGS (tokens)** — Whisper transcription + LLM summary/chat. Embeddings
  (`gte-small`) run in-region for free; audio is never stored.
- **Fixed infra** — Supabase Pro (~$25/mo), Apple Developer ($99/yr ≈ $8/mo),
  domain (~$1/mo), landing/appcast hosting (Vercel free) ≈ **~$35/mo** at start.

**Assumptions:** mix **80% Starter / 20% Pro**, billing **70% monthly / 30%
yearly**, average usage Starter ~6 hrs, Pro ~25 hrs, **COGS $0.15 / meeting-hour**
(estimate — see caveat).

Per paid user / month (blended): revenue $13.90 − commission $1.06 − tokens
$1.47 = **contribution ≈ $11.4**.

| Paid users | Revenue/mo | − Commission | − Tokens | − Fixed | = **Net profit/mo** | **/year** |
|---|---|---|---|---|---|---|
| **10** | $139 | −$11 | −$15 | −$35 | **≈ $79** | ~$0.9k |
| **50** | $695 | −$53 | −$74 | −$40 | **≈ $529** | ~$6.3k |
| **100** | $1,390 | −$106 | −$147 | −$50 | **≈ $1,087** | ~$13k |
| **1,000** | $13,900 | −$1,060 | −$1,470 | −$150 | **≈ $11,220** | **~$135k** |

- **Break-even ≈ 4–6 paying users.** Every user beyond that is profit.
- **Rule of thumb:** ~**$11 net per paid user / month** after everything.

> ⚠️ **Validate COGS with real data.** The $0.15/hr token cost is an estimate.
> `usage_events` already logs `cost_usd` per call — pull the actual average cost
> per user and replace the figure above before locking public prices.

## How this maps to the codebase (no new machinery)

- **Devices (1 / 3)** — set `profiles.device_limit` per tier. The single-device
  lock (`user_devices` + `claim_device`, enforced in `llm-proxy`) already reads
  this value; see [`security.md`](./policies/security.md) "Access control".
- **Hour limits** — sum `usage_events.audio_seconds` per user per billing cycle;
  at 100% surface the overage upsell / next-cycle reset.
- **Knowledge base (Pro-only)** — feature-flag `kind:"search"` without a
  `meeting_id` in `llm-proxy` (cross-session "Ask Nod").
- **Billing** — Merchant of Record + webhooks set the user's `tier` on their
  `profiles` row; the proxy reads `tier` to resolve limits and feature gates.

## Open decisions

- Entry price floor: **$12** (current) vs $9 (max volume, thinner margin) vs $15
  (safer margin).
- Founder-lock cap (currently first 500) and whether the locked price applies to
  monthly, yearly, or both.
- Exact overage pack sizes/prices once real COGS is known.
