# Nod policies

Working drafts of every policy and trust document Nod ships during beta.
Pages target `hellonod.app/policies` — markdown here, mirrored to the
marketing site.

> **Status:** Nod is in **private beta**, operated by an individual
> developer (Dima Barabash). No company is incorporated yet — that's
> disclosed honestly on every public-facing page. The privacy and
> security commitments are real and tied to code in this repo; the
> legal-entity-dependent parts (governing law, registered address, lead
> supervisory authority) are deferred to incorporation.

All drafts reflect Nod **as it actually works in this repo** at the date
shown on each document. Claims about data handling, retention, and
infrastructure are verified against the codebase and Supabase project
state.

## Trust & security

- [Security & Privacy](./security.md) — how data flows, where it's
  stored, what's encrypted, what's never stored.
- [Recording & Consent](./consent.md) — your responsibility to inform
  participants, jurisdiction quick reference, copy-paste template.
- [Subprocessors](./subprocessors.md) — every third party that touches
  your data, plus the no-train basis for each.
- [Cookie Policy](./cookies.md) — optional website analytics storage,
  purposes, retention, and controls.

## Legal

- [Terms of Service](./terms.md) — the agreement that governs use of
  the Service.
- [Privacy Policy](./privacy.md) — GDPR-aligned notice of what we
  collect, why, and your rights.
- **Data Processing Agreement (DPA)** — available on request from
  **dmytro@hellonod.app**.

## Open source

- **Third-Party Licenses** — auto-generated attribution for OSS
  dependencies. To be added before launch.

---

## Still to do

### Before opening the beta to the public

| Item | Notes |
|---|---|
| Publish these pages on `hellonod.app/policies` | mirror md → website (static is fine) |
| Generate Third-Party Licenses page | one OSS dep today (`supabase-swift`, Apache 2.0); regenerate before each release |

### Before the paid tier launches

| Item | Notes |
|---|---|
| Incorporate a company | replaces "Dima Barabash, individual developer" everywhere; legal entity, registered address, governing-law jurisdiction, lead supervisory authority all become real |
| Lawyer review | Privacy + Terms, especially refunds, governing law, EU/US transfer mechanisms |
| Paddle integration + refund flow | section 7 of `terms.md` describes the target |
| Update all policies, notify existing users | at least 30 days' notice; bump "Last updated" |

### Nice to have

| Item | Notes |
|---|---|
| DPA template PDF | only needed when a B2B buyer asks; happy to draft on request |
| Status page | once we have paying users; until then a tweet works |

---

## Conventions

- **Plain English first**, legalese only where required.
- **Match reality.** If a claim doesn't match the code, fix it (the doc,
  the code, or both — see [memory `feedback-plan-matches-codebase`]).
- **Date every document.** Bump the "Last updated" line on every
  material change.
- **No marketing language inside legal docs.** Save that for `/security`
  and the marketing site.
