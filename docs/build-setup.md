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

## Measuring a diarization change

Do not decide a diarization change from published benchmarks. AMI and DIHARD are
close-talking microphones in quiet rooms; our input is one mixed stream that has
already been through a conferencing codec at a low bitrate, noise suppression and
automatic gain control — all three tuned to keep speech intelligible rather than
to keep voices distinguishable. A pipeline can win on AMI and lose here.

`NodTests/DiarizationBenchmarkTests` replays the real diarizer over real meetings
and reports **accuracy per transcript line**, split into lines given to the wrong
person and lines left unattributed, plus how many voices it found against how
many there were.

Per line, not frame-level DER, because that is what the pipeline actually
produces: the VAD hands `DiarizationBuffer` speech only, clustering runs on that
concatenated timeline, and what ships is one cluster per line. DER's missed and
false-alarm terms would be measuring a silence stage that is not there. The split
still matters — phantom speakers (the failure that got diarization rolled back
once) read as wrong lines with a positive voice-count error, where a merge reads
as wrong lines with a negative one.

It skips unless `NOD_DIARIZE_FIXTURES` names a directory, and that is not a
convenience — fixtures are recordings of real meetings with real people, so they
never go in the repository. CI never runs this; you do, on your own calls.

**Capturing a fixture.** A Debug build with `defaults write com.example.nod
debug.audio.dump -bool YES` writes, at the end of a recording, exactly what the
diarizer received:

```
<timestamp>-diarization.wav          the concatenated speech, 16 kHz mono
<timestamp>-diarization.spans.json   where each transcript line sits in it
```

**Writing the truth.** A `.truth.json` beside them, sharing their base name
(`<timestamp>-diarization.truth.json` — the runner pairs on it, and a mismatch
silently yields zero fixtures and a skip), keyed by line number —
1-based, in transcript order, which is the order of the spans:

```json
{"speakers": {"1": "Anna", "2": "Anna", "3": "Leo"}}
```

Open the meeting, read down the transcript, put a name on each line. Leave a line
out when even a person cannot tell (two people at once) — omitted lines are not
scored rather than being guessed at.

```sh
NOD_DIARIZE_FIXTURES=~/nod-diarization xcodebuild test \
  -project Nod.xcodeproj -scheme Nod -destination 'platform=macOS' \
  -only-testing:NodTests/DiarizationBenchmarkTests
```

The run sweeps the distance threshold and compares every setting against pinning
the voice count from the calendar — the configuration a meeting with an
invitation actually uses, and the first thing worth knowing, because it decides
how much of this problem EventKit already solves.

The scorer itself (`NodTests/DiarizationScore.swift`) is covered by
`DiarizationScoreTests` on synthetic lines, so it runs in CI without any audio.

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

## Adding a macOS permission

**The hardened runtime needs its own entitlement, even though Nod is not
sandboxed.** This is the trap: the entitlements are documented as App Sandbox
keys, and every instinct says an unsandboxed app doesn't need them. It does —
`ENABLE_HARDENED_RUNTIME` is on, and `tccd` refuses to *put the question to the
user at all* without the matching key in `Nod/Nod.entitlements`
(`com.apple.security.device.audio-input` for the microphone,
`com.apple.security.personal-information.calendars` for the calendar).

The failure mode is silent and reads exactly like a bug in the app: the request
returns `false` **without throwing**, the authorization status stays
`notDetermined` however many times you ask, and the app never appears in System
Settings → Privacy & Security. Nothing distinguishes it from a user saying no.

`tccd` is the only place that says what happened. `log` is shadowed by a shell
function in some setups — call it by path:

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.TCC"' --info --debug \
  | grep -iE "com.example.nod|Policy disallows|Prompting policy"
```

The line to look for names the missing key outright:

```
Prompting policy for hardened runtime; service: kTCCServiceCalendar requires
entitlement com.apple.security.personal-information.calendars but it is missing
Policy disallows prompt for Sub:{com.example.nod}; access to kTCCServiceCalendar denied
```

Usage-description strings in `project.yml` are necessary but not sufficient: a
missing string crashes at the prompt, a missing entitlement suppresses it.

## Logs

All app logs flow through `Nod/Core/Log.swift` — namespaced by subsystem
(`Log.ui`, `Log.audio`, `Log.stt`, `Log.llm`), backed by `os.Logger` with
subsystem `com.example.nod`. Each call also mirrors to stdout for Xcode's
console. Filter externally with:

```sh
log show --predicate 'subsystem == "com.example.nod"' --last 5m
```
