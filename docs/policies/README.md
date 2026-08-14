# Nod policies

Every policy and trust document Nod ships. Pages target
`hellonod.app/policies` — markdown here, mirrored to the marketing site.

> **Status:** every page names **Nod** as the counterparty and data
> controller. No page names a person, describes the operator's legal
> form, or explains anything by reference to its absence — keep all three
> out. The privacy and security commitments are tied to code in this
> repo; the entity-dependent parts (governing law, registered address,
> lead supervisory authority) stay unstated until there is an entity to
> state.

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
| Incorporate a company | substitutes the entity name for "Nod" as counterparty and controller; registered address, governing-law jurisdiction and lead supervisory authority all become real and get stated |
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
