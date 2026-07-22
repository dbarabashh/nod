---
description: Don't write comments; the rare exception is a non-obvious WHY.
globs: '*.swift'
alwaysApply: true
---

- Don't write comments. The default is zero — code explains itself through good names, small functions, and clear types.
- If you reach for a comment to explain WHAT the code does, rewrite the code instead: rename the variable, extract the function, split the expression.
- Never add narration that restates the next line (`// increment the counter`).
- Never add section headers or banners (`// MARK: -` used as decoration, `// --- setup ---`).
- Never add task, fix, author, or caller references (`// added for issue #14`, `// TODO`, `// called from ContentView`) — the diff, PR, and issue tracker carry that.
- Never leave commented-out code. Delete it; git remembers.
- Never add docstrings on self-evident members.
- The only exception is a non-obvious WHY the code cannot express, where omitting it would lead the next reader to "fix" a deliberate choice: a hidden external constraint ("Whisper hallucinates on silence"), a subtle invariant ("must be called on `queue`"), or a workaround for a specific upstream bug.
- If you're unsure whether a comment clears that bar, it doesn't — delete it.
