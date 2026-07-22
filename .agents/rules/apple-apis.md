---
description: Verify Apple framework APIs against the docs (sosumi MCP) instead of recalling them.
globs: '*.swift'
alwaysApply: false
---

- Check the docs before writing non-trivial framework code (`AVAudioEngine`, `ScreenCaptureKit`/`SCStream`, `AppKit`/`NSPanel`, TCC/permissions, EventKit) — don't rely on recalled signatures.
- Use the project-scoped **sosumi** MCP server (`.mcp.json`): `mcp__sosumi__searchAppleDocumentation` to find the symbol, `mcp__sosumi__fetchAppleDocumentation` to read the page, `mcp__sosumi__fetchAppleVideoTranscript` for WWDC sessions.
- Always confirm availability against our macOS 13.0 deployment target — a macOS 14+ API needs `if #available`, not a target bump.
- Verify against the docs first whenever a framework behaves surprisingly, before working around it.
