---
description: The Xcode project is generated — edit project.yml and regenerate, never the pbxproj.
globs: 'project.yml, *.pbxproj, *.xcconfig'
alwaysApply: false
---

- Never edit `Nod.xcodeproj` by hand. Change `project.yml` and run `xcodegen generate`.
- Run `xcodegen generate` after adding or removing any source file — the project is generated from `path: Nod` scanning, but build settings and scripts are not.
- Keep the build universal (arm64 + x86_64) and the deployment target at macOS 13; a macOS 14+ API needs an availability gate, not a target bump.
- Keep `SWIFT_OBJC_BRIDGING_HEADER` in sync if `Nod/Core/Audio/` moves — the path is hardcoded.
- Keep SwiftFormat/SwiftLint versions in `ci.yml` in lockstep with local Homebrew versions, or CI and the pre-commit hook will disagree. Details: `docs/build-setup.md`.
- Don't build against `Vendor/sherpa-onnx.xcframework` without generating it first: `./scripts/fetch-vad-xcframework.sh`. It is not committed.
