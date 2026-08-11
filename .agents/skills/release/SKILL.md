---
name: release
description: Ship a Nod release — bump version, build, sign, notarize, package the DMG, generate the Sparkle appcast, and publish. Use when the user asks to cut a release, ship a version, publish an update, or push a new build to users.
---

# Cut a Nod release

`scripts/release.sh` is the turn-key pipeline: version bump → build & sign the
`.app` → notarized + stapled `.dmg` → EdDSA-signed appcast → GitHub Release +
landing-site push. The same DMG serves the website download button and Sparkle's
in-app updater.

Full background — one-time Sparkle key setup, notarization credentials, appcast
hosting — is in `docs/release.md`. Read it if any precondition below fails.

## Preconditions — check all before touching anything

1. Working tree is clean and on `main` (`git status`). Stop and ask if not.
2. `Vendor/sherpa-onnx.xcframework` exists — the script fetches it, but confirm
   the fetch succeeded rather than debugging a link error later.
3. Sparkle tools are reachable: `SPARKLE_BIN_DIR` points at an unpacked Sparkle
   distribution matching the SPM version pinned in `project.yml`.
4. Notarization credentials are stored (`xcrun notarytool store-credentials
   nod-notary`). Without them, only `--skip-notarize` builds work, and those
   show "developer cannot be verified" to every other user — never publish one.
5. `gh auth status` is alive if publishing.

## Steps

1. **Dry-run first**: `./scripts/release.sh <patch|minor|major|X.Y.Z> --dry-run`
   and show the user what it plans to do.
2. **Run it**: `./scripts/release.sh patch` (or the explicit version). Flags:
   - `--skip-notarize` — local Sparkle testing only, never for users
   - `--no-publish` — build everything, leave artifacts in `dist/` for inspection
3. **Verify the artifacts** in `dist/` before the publish step completes: the
   DMG opens, the appcast entry has an `sparkle:edSignature`, and the version in
   `project.yml` matches the tag.
4. **Confirm the update path** — Sparkle resolves the appcast from GitHub Pages
   and the download from GitHub Releases' `/latest/download/` redirect.

## Rules

- Never commit the EdDSA private key. It lives in the macOS Keychain; the
  `*.ed25519` glob in `.gitignore` is a safety net, not a workflow.
- Never hand-edit `appcast.xml` — regenerate it.
- `public/dmg/` on nod-landing holds only what the feeds still point at, plus
  `Nod-latest.dmg`. The release script prunes the rest automatically; do not
  add builds there by hand, and do not "keep one just in case" — a superseded
  DMG left on the CDN is a publicly downloadable copy of the version the
  update was meant to replace.
- The release commit follows the repo convention: lowercase, 4–5 words
  (`release 12.10.1`), no AI attribution trailer.
- If notarization fails, stop and surface Apple's log URL. Don't retry blindly
  and don't fall back to `--skip-notarize` for a real release.
