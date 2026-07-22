---
description: All logging goes through Log.<area>, never print.
globs: '*.swift'
alwaysApply: false
---

- Always log via `Log.<area>` (`Log.ui`, `Log.audio`, `Log.stt`, `Log.llm` — see `Nod/Core/Log.swift`). Never introduce `print(...)`; it isn't filterable.
- Use `.info` for normal flow, `.error` for recoverable errors, `.debug` for chunk-level detail that would spam production logs.
- Emit one line per event. Multi-line messages are hard to filter.
- Never log user content (transcript text, summary text) at `.info`. `.debug` is acceptable behind a flag.
- Filter externally with `log show --predicate 'subsystem == "com.example.nod"' --last 5m`.
