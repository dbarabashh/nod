---
description: Public policy docs are bound to specific code — flag the doc when you touch the code.
globs: 'docs/policies/**, supabase/**, Nod/Core/Backend/**, Nod/Features/Consent/**'
alwaysApply: false
---

- Proactively flag the matching policy doc when you change bound code, even if the user didn't ask for the doc update. The full code → doc table is in `docs/policy-bindings.md`.
- Bump the `_Last updated:_` line on every policy you edit.
- Keep the "what we do not collect" list in `privacy.md` § 3.8 literally true — adding any analytics SDK or first-party telemetry event invalidates it.
- Bump `ConsentPreference.disclaimerVersion` whenever the consent body in `ConsentStrings.swift` changes, and update `consent.md` + `privacy.md` § 3.3.
- Keep policy wording neutral about who operates Nod: **Nod** is the named counterparty in `terms.md` and the named data controller in `privacy.md` § 1. Never name a person, never describe the operator's legal form ("an individual", "not an incorporated company", "not a registered company", "individual developer"), and never explain a consequence by the absence of an entity — state the consequence and drop the "because". Contact stays `dmytro@hellonod.app`. Don't reintroduce "private beta" framing either; it was deliberately dropped on 2026-08-01.
- Mirror every policy edit into `nod-landing/src/content/policies/` — the published page is what a buyer's security review reads, and the two copies drift silently.
- Never claim a security control the code doesn't implement. Every policy claim must be traceable to code in this repo.
