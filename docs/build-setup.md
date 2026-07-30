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

## First-time setup — diarization models (required before the first build)

Speaker diarization loads two ONNX models from the app bundle. Together they are
~35 MB, so they are fetched rather than committed (checksum-pinned, which gives
the same reproducibility):

```sh
./scripts/fetch-diarization-models.sh   # pyannote segmentation-3.0 + wespeaker CAM++ → Nod/Core/Resources/
```

- **Required to build**, unlike the VAD xcframework's build-time-only role: both
  files are listed in Copy Bundle Resources, and a `Check diarization models`
  pre-build phase fails with a pointer to this script when either is missing.
  Without that phase a fresh clone died on `Build input file cannot be found`.
- **CI fetches them too** (cached on the script's hash), before `xcodegen
  generate` — xcodegen only lists resources that exist on disk, so fetching
  later would leave CI building an app whose diarization can never load a model.
- At runtime their absence is survivable: `SpeakerDiarizer.bundled()` returns nil
  and transcripts fall back to source-based `Me` / `Them` labels.
- Licences: pyannote segmentation-3.0 is MIT (CNRS), wespeaker CAM++ is Apache
  2.0 — both redistributable inside a commercial app.
- To bump either: edit the URL + SHA-256 in the script, re-run with `--force`.

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
