---
description: Commit message format for this repo.
alwaysApply: true
---

- Write commit messages in all lowercase, max 4–5 words: `add llm proxy edge function`, `fix screen recording prompt`, `drop en/uk language constraint`.
- Never include an AI-attribution trailer — no `Co-Authored-By: Claude ...`, no `Co-Authored-By: Codex ...`, no `Generated with ...` line. Strip it if a tool adds one.
- Commit or push only when the user asks. If you're on `main` and the change isn't trivial, branch first.
- Don't commit generated or vendored artifacts: `Nod.xcodeproj` regeneration noise beyond `project.yml`, `Vendor/`, `dist/`.
