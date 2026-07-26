# Release flow

Nod ships auto-updates via [Sparkle 2](https://sparkle-project.org). Each
release goes through this pipeline:

1. Bump version
2. Build & sign the `.app`, package into a notarized + stapled `.dmg`
3. Generate the EdDSA-signed appcast
4. Publish DMG on GitHub Releases, publish `appcast.xml` on GitHub Pages

The same DMG serves two consumers: the website "Download for Mac" button
(via GitHub Releases' permanent `/latest/download/` redirect) and
Sparkle's in-app updater (via the appcast).

## One-time setup

### 1. Sparkle tools

Download the Sparkle distribution (matching the SPM version pinned in
`project.yml`) from <https://github.com/sparkle-project/Sparkle/releases>.
Unpack and remember the path to its `bin/` directory — it contains
`generate_keys`, `sign_update`, and `generate_appcast`.

```sh
# Example
export SPARKLE_BIN_DIR="$HOME/Downloads/Sparkle-2.9.2/bin"
```

### 2. EdDSA signing keys

```sh
"$SPARKLE_BIN_DIR/generate_keys"
```

This stores the private EdDSA key in the macOS Keychain (item
`https://sparkle-project.org`) and prints the matching public key. Copy the
public key into `project.yml`:

```yaml
SUPublicEDKey: "<your public key here>"
```

then `xcodegen generate` to refresh `Info.plist`. The private key never
leaves Keychain; the release script reads it from there via
`generate_appcast`.

> The `*.ed25519` glob in `.gitignore` is a safety net for anyone who
> exports the key locally — don't.

### 3. Notarization credentials

Store an app-specific password (or App Store Connect API key) once:

```sh
xcrun notarytool store-credentials nod-notary \
  --apple-id you@example.com \
  --team-id ABCDE12345 \
  --password <app-specific-password>
```

`nod-notary` is the profile name the release script expects via
`NOTARY_PROFILE`.

### 4. Landing page (Vercel)

The appcast and the marketing download button both live at
<https://nod-landing.vercel.app>. The `nod-landing` repo is a separate
GitHub project deployed to Vercel; on every release we copy the
freshly-generated `appcast.xml` into its `public/` directory and push.
Vercel auto-deploys within ~30s, and Sparkle clients see the update on
their next poll.

The URL must match `SUFeedURL` in `Info.plist`:

```
https://nod-landing.vercel.app/appcast.xml
```

DMG binaries are still hosted on GitHub Releases (free, supports the
`/releases/latest/download/<name>` permanent redirect that the landing's
"Download for Mac" button relies on). The appcast just references those
absolute URLs.

## Before cutting a release

```sh
./scripts/check-app-identifiers.sh
```

Both bundle-identifier lists — the messengers excluded from ambient capture
(`ScreenExclusions.defaultExcludedMessengers`) and the apps meeting detection
watches (`ConferencingApp`) — match by identifier, so an app that ships under a
second one is silently uncovered. That is how `com.tdesktop.Telegram`, the
Telegram build most people run, stayed readable by ambient capture while two
other Telegram identifiers sat in the list. The script flags any installed app
whose name says we cover it while its identifier says we don't. It reports on
the machine it runs on, so it catches what *you* have installed, not
everything that exists — run it on a Mac with the usual apps on it.

## Cutting a release

```sh
export VERSION=0.0.2
export BUILD=2
export NOTARY_PROFILE=nod-notary
export SPARKLE_BIN_DIR="$HOME/Downloads/Sparkle-2.9.2/bin"

./scripts/release.sh
```

The script:

- regenerates the Xcode project,
- stamps `CFBundleShortVersionString` / `CFBundleVersion`,
- archives + exports a Developer ID-signed `Nod.app`,
- packages it into `Nod-${VERSION}.dmg` (with an `Applications` symlink for
  drag-to-install UX),
- signs the DMG, submits to Apple's notary service, waits, staples the
  ticket,
- copies the DMG to `Nod-latest.dmg` (stable filename for the website),
- runs `generate_appcast` to produce `dist/appcast.xml` (EdDSA-signed
  against the Keychain key).

Then:

```sh
# 1. Upload both DMGs to the same GitHub Release. The versioned one is what
#    the appcast references; the -latest one is what the website button links to.
gh release create "v${VERSION}" \
  "dist/Nod-${VERSION}.dmg" \
  "dist/Nod-latest.dmg" \
  --title "Nod ${VERSION}" \
  --generate-notes

# 2. Push the appcast to the landing repo so Vercel serves it.
cp dist/appcast.xml /path/to/nod-landing/public/appcast.xml
cd /path/to/nod-landing
git commit -am "appcast ${VERSION}"
git push
```

Within ~30s Vercel will redeploy with the new appcast. Installed clients
hit `SUFeedURL` on their next scheduled check (≤ 24h) and are prompted to
update.

## Website download button (in nod-landing)

```html
<a href="https://github.com/dbarabashh/Nod/releases/latest/download/Nod-latest.dmg">
  Download for Mac
</a>
```

GitHub redirects `/releases/latest/download/<name>` to the asset of that
name in whichever release is marked "latest" — so the link never has to
change. Every release must upload an asset named exactly `Nod-latest.dmg`;
the script handles this automatically.

To display the current version next to the button without a build step on
the landing side, fetch `/appcast.xml` client-side (same-origin, so no
CORS) and read the latest `<sparkle:shortVersionString>`. Same source of
truth as the in-app updater.

### Why Vercel needs nothing special for appcast.xml

The file is plain XML in `public/`. Vercel serves static files with the
right `Content-Type` (`application/xml`) based on extension — Sparkle is
happy with that. No `vercel.json` rewrites needed.

## Why no Gatekeeper warning?

The DMG is **Developer ID-signed + notarized + stapled**. That combination
is what avoids the *"Nod cannot be opened because it is from an
unidentified developer"* dialog and the *"App is damaged"* error users
see on un-notarized apps:

- **Signed** with the Developer ID Application cert → Gatekeeper knows
  who shipped it.
- **Notarized** (Apple scanned the binary, returned a ticket) → Gatekeeper
  knows Apple accepts it.
- **Stapled** → the notarization ticket is glued to the DMG itself, so
  the first-launch check works even when the user is offline.

If any step is skipped, macOS shows a permission dialog and forces the
user into System Settings → Privacy & Security → "Open Anyway". Don't
ship a release until `xcrun stapler validate dist/Nod-${VERSION}.dmg`
succeeds and `spctl --assess` returns "accepted source=Notarized
Developer ID".

## Smoke-testing an update

1. Build and install `Nod 0.0.1` locally.
2. Run the release pipeline for `0.0.2`, publish the appcast.
3. Open the installed `0.0.1`. From the status-bar menu choose **Check
   for Updates…**.
4. Sparkle should download `Nod-0.0.2.zip`, verify the EdDSA signature
   against `SUPublicEDKey`, and prompt to relaunch.

If verification fails ("update is improperly signed"), the public key in
`Info.plist` doesn't match the private key in Keychain — most often
because `generate_keys` was run a second time and replaced the keychain
entry.

## Reference

- Sparkle 2 docs: <https://sparkle-project.org/documentation/>
- Notarytool: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>
- `Info.plist` keys used:
  - `SUFeedURL` — appcast URL Sparkle polls
  - `SUPublicEDKey` — EdDSA public key for verifying download signatures
  - `SUEnableAutomaticChecks` (`true`) — skip the first-launch prompt
  - `SUScheduledCheckInterval` (`86400`) — once per day
