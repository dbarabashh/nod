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

Store an App Store Connect API key once:

```sh
xcrun notarytool store-credentials Nod_New \
  --key ~/private_keys/AuthKey_XXXXXX.p8 \
  --key-id XXXXXX \
  --issuer <issuer-uuid>
```

`Nod_New` is the profile name the release script expects via `NOTARY_PROFILE`.

An app-specific password (`--apple-id … --team-id … --password …`) works too, but
prefer the API key: Apple revokes **every** app-specific password the moment the
Apple ID password changes, and the only symptom is `HTTP status code: 401` on the
next release — with the certificate, the team and the account all still fine.
That is exactly what happened between 12.10.1 and 12.11.0.

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
export NOTARY_PROFILE=Nod_New
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

## Releasing to a few accounts first

There are two ways to narrow the audience, and which one applies depends on what
the target Mac is already running.

| | `--channel` | `--feed` |
|---|---|---|
| Who is targeted | accounts, server-side | individual Macs |
| Setup on their Mac | none | one `defaults write`, once |
| Works on builds released before channel support | **no** | **yes** |
| Where the item lands | the public `appcast.xml`, tagged | `appcast-NAME.xml` only |

`--channel` is the better tool and the one to reach for by default. `--feed` is
what gets a build onto a Mac whose installed version predates the channel
delegate — including, at the time of writing, everyone.

```sh
./scripts/release.sh patch --channel beta --to a@x.com,b@y.com
./scripts/release.sh enroll   --channel beta --to c@z.com   # no build
./scripts/release.sh unenroll --to c@z.com                  # no build

./scripts/release.sh patch --feed beta --to riwwom@gmail.com
```

`--to` means different things in the two modes, and the difference is the whole
point of having both. With `--channel` it *is* the delivery mechanism. With
`--feed` it delivers nothing: the build reaches a Mac only because that Mac was
pointed at the feed, and a client from before channel support sends nothing the
server could route on — it just fetches the URL baked into its `Info.plist`.
Passing `--to` alongside `--feed` only puts the account on the matching channel
in advance, so the manual step never has to be repeated for that person.

A channel build goes into the **same** `appcast.xml` everyone polls, tagged
`<sparkle:channel>beta</sparkle:channel>`. Sparkle only offers a tagged item to
clients whose `allowedChannelsForUpdater:` returns that channel — for us, the
accounts in `release_channel_members`, which `ReleaseChannelStore` reads at
launch and caches in `UserDefaults` (Sparkle asks for the channel synchronously
inside its check, so a live read would be too late).

Compared with a normal release, a channel run also:

- skips the `app_config.recommended_build` bump — the banner has no notion of
  channels and would nag everyone toward a build they cannot download;
- leaves `Nod-latest.dmg` alone, so the website keeps serving the last build
  everyone is allowed to have;
- marks the GitHub release `--prerelease`, which keeps it out of
  `/releases/latest`.

### Private feeds (`--feed`)

`--feed beta` writes `public/appcast-beta.xml` and leaves `appcast.xml` byte-for-byte
alone, so nothing changes for anyone who was not pointed at it. Pointing a Mac at
it is one command, run once, with Nod quit:

```sh
defaults write com.example.nod SUFeedURL "https://hellonod.app/appcast-beta.xml"
defaults delete com.example.nod SUFeedURL     # back to the public feed
```

This is core Sparkle behaviour, not a trick: `SPUUpdater` resolves the feed URL
through `SUHost.objectForKey:`, which reads user defaults before `Info.plist`.
It works because we set no `feedURLStringForUpdater:` delegate — that method takes
priority over both, so adding one would silently break every private feed.

From there it is a normal Sparkle update: scheduled check, EdDSA verification,
download, relaunch. Nothing is installed by hand.

Two properties keep this from turning into a second release train:

- a **new** private feed is seeded from the public one, so the Mac reading it
  keeps every build it was already entitled to;
- a **general** release is written into `appcast.xml` *and* every existing
  `appcast-*.xml`, so a Mac left on a private feed still receives it.

## A build on the sandbox database (`--sandbox`)

```sh
./scripts/release.sh patch --sandbox
```

Channels and private feeds both narrow *who gets a build of the app*. This
narrows *which database the app talks to*, which is a different axis and needs a
different mechanism: a third Xcode configuration, `Sandbox`, optimised exactly
like Release but compiled with `NOD_SANDBOX`.

What that produces is a genuinely separate app:

| | Release | Sandbox |
|---|---|---|
| Bundle id | `com.example.nod` | `com.example.nod.sandbox` |
| Name on disk | `Nod.app` | `Nod Sandbox.app` |
| Icon | `AppIcon` | `AppIcon-Sandbox` (the same art with a label across the foot) |
| Database | prod | the `develop` branch |
| OAuth callback | `nod://auth-callback` | `nod-sandbox://auth-callback` |
| MCP connector | `hellonod.app/mcp` | `hellonod.app/mcp-sandbox` |
| Updates from | `appcast.xml` | `appcast-sandbox.xml` |

They install side by side, take their permissions separately, and neither can be
offered the other's update. The separate URL scheme is not cosmetic: two
installed apps registering `nod://` would leave macOS to pick one for the OAuth
callback, and the loser would never finish signing in.

**The sandbox feed is quarantined in both directions.** A general release is
written into `appcast.xml` and every private `appcast-*.xml` — that fan-out is
what keeps a tester from being stranded, and it explicitly skips
`appcast-sandbox.xml`. Going the other way, a new private feed is normally seeded
from the public one; the sandbox feed starts empty instead. Either leak would end
with a prod-built binary installing over the sandbox app, which would then come
back up on production data without anyone touching a setting.

It also differs from a normal run in what it does *not* do: no git tag, no push,
no GitHub Release, no `recommended_build` bump, and the version stamp is put back
afterwards, because a sandbox build is not a release of anything the team owns.
For the same reason it is the one mode cuttable from a branch — handing someone
work before it merges is the point.

Build numbers are counted against the sandbox feed alone, so the two tracks never
burn each other's numbers.

### Before the first one

Three things live outside this repo and are not checked by the script:

- the sandbox branch's auth allowlist and the Google OAuth client both need
  `nod-sandbox://auth-callback`, or sign-in fails at the provider;
- `nod-landing` needs the `/mcp-sandbox/:token` rewrite deployed, or the
  connector fails its OAuth probe (see the comment in `SupabaseConfig.swift`);
- edge-function secrets are per branch and inherit nothing from prod.

### Regenerating the icon

`AppIcon-Sandbox.appiconset` is derived, not drawn:

```sh
swift scripts/make-sandbox-icon.swift
```

Run it after any change to `AppIcon.appiconset`. Note that `actool` reports a
wrong-sized icon as a *warning* and then ships no icon at all, so check for
`AppIcon-Sandbox.icns` in the built bundle rather than trusting a green build.

### How the tracks converge

Build numbers are global: the script takes `max(Info.plist, every
sparkle:version in the published feed) + 1`. So the next default release always
outranks any outstanding beta, and Sparkle — which does not let a client opt
*out* of the default channel — offers it to the testers too. There is nothing to
un-enrol before a general release.

Sparkle's own guidance is that channels are branches that converge back into the
default track, not parallel trains; a track that is never superseded wants a
separate feed URL instead.

### What to expect

| Situation | What happens |
|---|---|
| Tester's app is older than the first channel-aware build | It ignores tagged items entirely. Hand them that first DMG directly — this is the one case channels can't bootstrap themselves. |
| You un-enrol someone on a newer build | Nothing. Sparkle never downgrades; they sit there until the default track passes them. |
| You want the beta for everyone | Cut a normal release from the same commit. Editing the channel out of a published item by hand is not worth the risk. |
| A tester never launches the app after enrolment | No channel is cached, so no beta. One launch fixes it. |
| Typo in `--to` | The RPC reports the unmatched address and the script aborts **before** building. |
| Enrolled on several Macs | Channel is per account, so all of them. |

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
