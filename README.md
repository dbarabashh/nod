# Nod

A SwiftUI macOS app that displays a floating, non-activating overlay panel on the
left side of the screen — styled like Spotlight/Raycast. Records meetings,
transcribes via Whisper, and acts as a recall-oriented memory aid (not a
real-time suggestion / cheat tool).

## Run

```sh
open Nod.xcodeproj
```

Then press ⌘R in Xcode. The app launches as an accessory (`LSUIElement = YES`),
so no Dock icon appears — only the floating panel.

To rebuild from CLI:

```sh
xcodebuild -project Nod.xcodeproj -scheme Nod build
```

To regenerate the Xcode project from `project.yml` after adding files:

```sh
xcodegen generate
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
defaults write com.example.nod whisper.model "whisper-large-v3"

# Optional: STT/UI language ("en" or "uk"); also toggleable from the UI chip.
defaults write com.example.nod app.language "uk"
```
