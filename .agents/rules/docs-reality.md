---
description: Plan and product docs describe what the code does, not what we hope it does.
globs: 'README.md, docs/**, AGENTS.md'
alwaysApply: false
---

- Make every claim in a doc match what the code actually does today, or what an unchecked `- [ ]` task will make it do. No aspirational marketing language.
- Never reference a file that doesn't exist. (`PLAN.md` was cited by the old agent instructions for months and was never committed — don't reintroduce it.)
- Check a GitHub issue's "Blocked by" section before starting it. Larger epics live in the Linear `NOD` project.
- Keep `docs/` factual and dated: bump the `_Last updated:_` line whenever you edit a policy.
- Don't describe a subproject's behavior from memory — the sibling repos are mapped in `docs/ecosystem.md`.
