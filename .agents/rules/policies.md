---
description: Public policy docs are bound to specific code — flag the doc when you touch the code.
globs: 'docs/policies/**, supabase/**, Nod/Core/Backend/**, Nod/Features/Consent/**'
alwaysApply: false
---

- Proactively flag the matching policy doc when you change bound code, even if the user didn't ask for the doc update. The full code → doc table is in `docs/policy-bindings.md`.
- Bump the `_Last updated:_` line on every policy you edit.
- Keep the "what we do not collect" list in `privacy.md` § 3.8 literally true — adding any analytics SDK or first-party telemetry event invalidates it.
- Bump `ConsentPreference.disclaimerVersion` whenever the consent body in `ConsentStrings.swift` changes, and update `consent.md` + `privacy.md` § 3.3.
- Keep the status header accurate: Nod is in private beta, operated by Dima Barabash as an individual developer — no company, no SOC 2, contact `dbarabashdev@gmail.com`.
- Never claim a security control the code doesn't implement. Every policy claim must be traceable to code in this repo.
