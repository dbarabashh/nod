# Build, run, and tooling setup

Targets macOS 13+, Swift 5.9, **universal (Apple silicon + Intel)**. SPM deps:
`supabase-swift` v2+, `Sparkle` v2+. Bundle ID: `com.example.nod`.

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — **never edit
`Nod.xcodeproj` by hand.**

```sh
# After adding/removing source files or editing project.yml:
xcodegen generate

# Open in Xcode, then ⌘R:
open Nod.xcodeproj

# CLI build:
xcodebuild -project Nod.xcodeproj -scheme Nod build

# CLI tests (NodTests bundle target — unit tests for the pure helpers):
xcodebuild -project Nod.xcodeproj -scheme Nod -destination 'platform=macOS' test
xcodebuild -project Nod.xcodeproj -scheme Nod test -only-testing:NodTests/TranscriptDedupTests/testIdenticalTextMatches
```

## First-time setup — VAD dependency (required before the first build)

Nod links a vendored, universal (arm64 + x86_64) static build of
**sherpa-onnx** (on-device Silero VAD + bundled onnxruntime) at
`Vendor/sherpa-onnx.xcframework`. It is **not** an SPM package (sherpa-onnx
ships none) and is **not** committed — the universal static lib contains a file
over GitHub's 100 MB limit. Generate it once per clone, before building:

```sh
./scripts/fetch-vad-xcframework.sh   # downloads the pinned sherpa-onnx release, builds the xcframework into Vendor/
xcodegen generate                    # then build / open Nod.xcodeproj as usual
```

- **Build-time only.** The xcframework is statically linked into the app —
  nothing extra is embedded, signed, or shipped. A downloaded `.app` is fully
  self-contained (VAD code + the bundled `silero_vad.onnx` model), so end users
  need none of this.
- The Silero model (`Nod/Core/Resources/silero_vad.onnx`, ~600 KB) **is** committed.
- `scripts/release.sh` runs the fetch step automatically.
- To bump sherpa-onnx: edit `SHERPA_VERSION` + `SHA256` in the script, re-run
  with `--force`.

## Diarization models — nothing to fetch

Speaker diarization runs on [Argmax SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift)
(MIT), a Swift package resolved by SPM like Supabase and Sparkle. It runs pyannote
on Core ML / the Neural Engine.

- **No build step and no committed payload.** The Core ML models come from the
  `argmaxinc/speakerkit-coreml` repo on Hugging Face, downloaded on first use and
  cached on disk — so the first diarized meeting after a fresh install needs the
  network and every later one does not. No audio ever leaves the device.
- A failed download is survivable: `SpeakerDiarizer.make()` returns nil and
  transcripts fall back to source-based `Me` / `Them` labels.
- Licences: the SDK is MIT (Argmax); the pyannote community models are CC-BY-4.0,
  which requires attribution but permits commercial use.
- Cluster tuning is the SDK's job now. `defaults write com.example.nod
  diarization.threshold 0.55` still overrides the distance threshold for field
  debugging; unset, SpeakerKit picks it.

## Lint, format, and git hooks

```sh
brew install swiftlint swiftformat        # required for the build phase + pre-commit hook
git config core.hooksPath .githooks       # one-time per clone — enables the pre-commit hook
```

SwiftLint runs as a build phase (`project.yml` → `preBuildScripts`). The
pre-commit hook (`.githooks/pre-commit`) auto-formats staged Swift files with
SwiftFormat, then blocks the commit only on **error-level** SwiftLint
violations in staged files (force-unwrap/cast/try). Configs: `.swiftlint.yml`,
`.swiftformat` — both tuned to the rules in `.agents/rules/`.

`.claude/settings.json` also runs SwiftFormat as a `PostToolUse` hook, so a
file an agent edits is formatted immediately rather than at commit time.

### CI pins these tools — keep the pins in lockstep with local

The `ci.yml` `build-test` job lints the whole repo (`swiftformat --lint .`,
`swiftlint lint`). Homebrew tracks *latest*, whose default rule set drifts from
local: a newer SwiftFormat enabled `wrapIfStatementBodies` by default and
failed CI on files no local run ever flagged. So CI downloads **pinned**
release binaries (SwiftFormat `0.61.1`, SwiftLint `0.63.3`) and prepends them
to `PATH` — the runner also pre-installs newer builds at `/opt/homebrew/bin`
that would otherwise win.

When you upgrade your local SwiftFormat/SwiftLint, bump
`SWIFTFORMAT_VERSION`/`SWIFTLINT_VERSION` in `ci.yml` to match, or CI and the
pre-commit hook will disagree.

## Logs

All app logs flow through `Nod/Core/Log.swift` — namespaced by subsystem
(`Log.ui`, `Log.audio`, `Log.stt`, `Log.llm`), backed by `os.Logger` with
subsystem `com.example.nod`. Each call also mirrors to stdout for Xcode's
console. Filter externally with:

```sh
log show --predicate 'subsystem == "com.example.nod"' --last 5m
```
