# Nod

A SwiftUI macOS app that displays a floating, non-activating overlay panel on the
left side of the screen — styled like Spotlight/Raycast. Records meetings,
transcribes via Whisper, and acts as a recall-oriented memory aid (not a
real-time suggestion / cheat tool).

## Prerequisites

- **Xcode** — targets macOS 13+, Swift 5.9.
- **XcodeGen** — `brew install xcodegen`. The `.xcodeproj` is generated from
  `project.yml`; never edit it by hand.
- **Supabase CLI** — only if you touch the backend (schema, Edge Functions, secrets).

## Run

```sh
xcodegen generate   # after pulling, or after adding/removing source files
open Nod.xcodeproj   # then ⌘R
```

The app launches as an accessory (`LSUIElement = YES`), so no Dock icon
appears — only the floating panel. To build from the CLI:

```sh
xcodebuild -project Nod.xcodeproj -scheme Nod build
```

## Configuration

LLM + Whisper traffic flows through the `llm-proxy` Supabase Edge Function;
the OpenRouter API key lives server-side in `OPENROUTER_API_KEY` (Supabase
secrets) — there is **no client-side API key**. Sign in to the app and the
Supabase JWT authenticates every call.

Dev overrides (UserDefaults):

```sh
# Optional: chat model (forwarded to OpenRouter via the proxy)
defaults write com.example.nod openrouter.model "anthropic/claude-haiku-4-6"

# Optional: Whisper model (forwarded to OpenRouter via the proxy)
defaults write com.example.nod whisper.model "openai/whisper-large-v3-turbo"

# Optional: STT/UI language code (e.g. "en", "uk", "sr"); also toggleable
# from the UI chip. Supported set lives in Nod/Language/AppLanguage.swift.
defaults write com.example.nod app.language "uk"
```

## Release builds

Releases are turn-key:

```sh
./scripts/release.sh <patch|minor|major|X.Y.Z>
```

It bumps the version, regenerates the project, builds, signs, notarizes, makes a
DMG, signs the Sparkle appcast, and publishes to GitHub + the `nod-landing`
site. The script's preflight checks each requirement below and tells you what's
missing — first-time setup on a new machine:

1. **Sparkle tools** at `~/Downloads/Sparkle-2.9.2/bin`. They ship with the SPM
   dependency, so just copy them out (no separate download):
   ```sh
   cp -R ~/Library/Developer/Xcode/DerivedData/Nod-*/SourcePackages/artifacts/sparkle/Sparkle/bin/ \
         ~/Downloads/Sparkle-2.9.2/bin/
   ```
2. **Developer ID cert** — a "Developer ID Application" identity in your login
   keychain (check: `security find-identity -v -p codesigning`). Move it between
   Macs by exporting a `.p12` from Keychain Access (it carries the private key).
3. **Notary profile** — store Apple credentials once (needs an app-specific
   password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials nod-notary-2 \
     --apple-id <apple-id> --team-id <TEAMID>
   ```
4. **Landing repo** — clone `nod-landing` as a sibling of this repo and link it
   to Vercel (requires the Vercel CLI, `vercel login`):
   ```sh
   cd ../nod-landing && vercel link --project nod-landing
   ```

Flags: `--dry-run` (print steps, change nothing), `--skip-notarize` (local test,
unsigned for other Macs), `--no-publish` (build only, no GitHub/Vercel push).
```

