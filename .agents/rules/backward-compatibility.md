---
description: Preserve every live contract until measured migration gates permit removal.
alwaysApply: true
---

- Treat every released client, deployed worker, website, dashboard, and external integration inside its support window as an active contract consumer; deploys do not become atomic because they share a repository.
- Evolve schemas, RPCs, Edge Functions, events, enums, payloads, policies, and stored data with expand → migrate → contract: add compatibility first, migrate and observe second, remove old behavior only in a later change.
- Never replace an accepted request version, required field, response shape, enum value, or stored meaning in place; accept old and new forms concurrently while supported consumers migrate.
- Require mixed-version tests that start from the previous production schema and exercise the oldest supported consumer beside the new one; a clean install of the final schema is not sufficient evidence.
- Document deploy order, rollback behavior, supported versions, and the observable retirement gate in every contract-changing PR.
- Create a linked Linear cleanup issue before merging any temporary compatibility or legacy path; include the exact telemetry window, minimum build, data state, and rollback conditions required for removal.
- Never remove compatibility from release age, download counts, or assumption; require production evidence of zero legacy traffic for the agreed window and completion of the linked cleanup issue.
- Reconcile every manual production fix immediately with a new forward migration, tests, and playbook incident context; never edit an already-applied migration to make history look correct.
- Never auto-upgrade consent, entitlement, privacy, or billing meaning during a technical migration; those states require their own explicit product-authorized transition.
