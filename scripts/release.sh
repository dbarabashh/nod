#!/usr/bin/env bash
# Nod release pipeline — turn-key.
#
# Usage:
#   ./scripts/release.sh patch              # 0.0.1 → 0.0.2
#   ./scripts/release.sh minor              # 0.0.1 → 0.1.0
#   ./scripts/release.sh major              # 0.0.1 → 1.0.0
#   ./scripts/release.sh 0.0.2              # explicit version
#
# Flags:
#   --skip-notarize   build + sign + DMG, skip Apple notarization
#                     (use when Apple Developer Program is still pending; the
#                     resulting DMG will show "developer cannot be verified"
#                     for any other user, but Sparkle's flow can be tested
#                     locally on your own machine)
#   --no-publish      build everything, skip gh release create + landing push
#                     (artifacts left in dist/ for inspection)
#   --dry-run         print what would happen, do nothing
#
# Required (env vars or auto-detected):
#   SPARKLE_BIN_DIR     default: $HOME/Downloads/Sparkle-2.9.2/bin
#   NOTARY_PROFILE      default: nod-notary-2  (skipped with --skip-notarize)
#   NOD_LANDING_REPO    default: <sibling of this repo>/nod-landing
#
# Optional:
#   SIGN_IDENTITY       default: "Developer ID Application"
#                       (override to "Nod Dev" + --skip-notarize for local tests)
#   SUPABASE_SERVICE_ROLE_KEY  bumps app_config.recommended_build to this build
#                       so the in-app update nudge tracks releases. If unset, the
#                       bump is skipped (with a warning) — set it from Supabase
#                       dashboard → Project Settings → API → service_role.
#   SUPABASE_API_URL    default: https://api.hellonod.app

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ───────────────────────── defaults / args ─────────────────────────

SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$HOME/Downloads/Sparkle-2.9.2/bin}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nod-notary-2}"
NOD_LANDING_REPO="${NOD_LANDING_REPO:-$(dirname "$REPO_ROOT")/nod-landing}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

SKIP_NOTARIZE=0
NO_PUBLISH=0
DRY_RUN=0
VERSION_ARG=""

usage() {
  sed -n '2,/^set -euo/p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-publish)    NO_PUBLISH=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       usage ;;
    *)               VERSION_ARG="$1" ;;
  esac
  shift
done

[ -n "$VERSION_ARG" ] || { echo "ERROR: version arg required (patch/minor/major or X.Y.Z)" >&2; usage; }

# ───────────────────────── helpers ─────────────────────────

die() { echo "❌ $*" >&2; exit 1; }
say() { echo "==> $*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" Nod/Info.plist; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" Nod/Info.plist; }

# ───────────────────────── compute next version ─────────────────────────

CURRENT_VERSION="$(plist_get CFBundleShortVersionString)"
CURRENT_BUILD="$(plist_get CFBundleVersion)"

case "$VERSION_ARG" in
  patch|minor|major)
    IFS='.' read -r MAJ MIN PAT <<< "$CURRENT_VERSION"
    case "$VERSION_ARG" in
      patch) PAT=$((PAT + 1)) ;;
      minor) MIN=$((MIN + 1)); PAT=0 ;;
      major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    esac
    VERSION="${MAJ}.${MIN}.${PAT}"
    ;;
  [0-9]*.[0-9]*.[0-9]*)
    VERSION="$VERSION_ARG"
    ;;
  *)
    die "version must be patch/minor/major or X.Y.Z (got: $VERSION_ARG)"
    ;;
esac

BUILD=$((CURRENT_BUILD + 1))

# ───────────────────────── preflight ─────────────────────────

say "Preflight"

# Git tree clean?
if [ -n "$(git status --porcelain)" ]; then
  die "working tree has uncommitted changes; commit or stash first"
fi

# On main?
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "release must be cut from main (currently on '$BRANCH')"

# Sparkle bin?
[ -x "$SPARKLE_BIN_DIR/generate_appcast" ] \
  || die "SPARKLE_BIN_DIR=$SPARKLE_BIN_DIR has no generate_appcast (download Sparkle distribution and unpack)"

# Public key not placeholder?
PUBKEY="$(plist_get SUPublicEDKey)"
case "$PUBKEY" in
  REPLACE_*) die "SUPublicEDKey is still placeholder — run 'sparkle generate_keys' and update project.yml" ;;
esac

# Signing identity available?
if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
  die "no codesigning identity matching '$SIGN_IDENTITY' in Keychain"
fi

# Notary profile?
if [ "$SKIP_NOTARIZE" = 0 ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "notary profile '$NOTARY_PROFILE' not set up. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id ... --team-id ... --password ..."
  fi
fi

# Landing repo?
if [ "$NO_PUBLISH" = 0 ]; then
  [ -d "$NOD_LANDING_REPO/.git" ] || die "NOD_LANDING_REPO=$NOD_LANDING_REPO is not a git repo"
  [ -d "$NOD_LANDING_REPO/public" ] || die "$NOD_LANDING_REPO has no public/ directory (Vercel static root expected)"
fi

# gh CLI?
if [ "$NO_PUBLISH" = 0 ]; then
  command -v gh >/dev/null || die "gh CLI not installed (brew install gh)"
  gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated (run: gh auth login)"
fi

# vercel CLI? — we trigger the appcast deploy explicitly via CLI rather than
# relying on Vercel's GitHub auto-deploy, which has silently disconnected
# before (every commit reaching origin but no new deployment building).
if [ "$NO_PUBLISH" = 0 ]; then
  command -v vercel >/dev/null || die "vercel CLI not installed (npm i -g vercel)"
  [ -f "$NOD_LANDING_REPO/.vercel/project.json" ] \
    || die "$NOD_LANDING_REPO is not linked to a Vercel project (run: cd $NOD_LANDING_REPO && vercel link)"
fi

echo "    Current: ${CURRENT_VERSION} (${CURRENT_BUILD})"
echo "    Next:    ${VERSION} (${BUILD})"
echo "    Sign:    $SIGN_IDENTITY"
echo "    Notarize: $([ "$SKIP_NOTARIZE" = 1 ] && echo 'SKIPPED' || echo "$NOTARY_PROFILE")"
echo "    Publish: $([ "$NO_PUBLISH" = 1 ] && echo 'SKIPPED' || echo "GitHub + $NOD_LANDING_REPO")"
[ "$DRY_RUN" = 1 ] && { echo "    [dry-run mode — exiting]"; exit 0; }
echo

# ───────────────────────── paths ─────────────────────────

DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/Nod-${VERSION}.xcarchive"
EXPORT_DIR="${DIST_DIR}/export"
APP_PATH="${EXPORT_DIR}/Nod.app"
DMG_STAGE="${DIST_DIR}/dmg-stage"
DMG_PATH="${DIST_DIR}/Nod-${VERSION}.dmg"
LATEST_DMG_PATH="${DIST_DIR}/Nod-latest.dmg"
APPCAST_PATH="${DIST_DIR}/appcast.xml"
# DMGs are served from Vercel rather than GitHub release assets: the source
# repo is private, so GitHub's release-download URLs return 404 to unauthenticated
# clients — and Sparkle is an unauthenticated client. nod-landing/public/dmg/
# is public via Vercel CDN, so the URL Sparkle resolves actually serves bytes.
APPCAST_BASE_URL="https://hellonod.app/dmg"

mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_STAGE}" "${DMG_PATH}" "${LATEST_DMG_PATH}"

# ───────────────────────── stamp version ─────────────────────────

say "Ensure VAD xcframework (sherpa-onnx)"
run "./scripts/fetch-vad-xcframework.sh"

say "Regenerate project"
xcodegen generate

say "Stamp ${VERSION} (${BUILD})"
plist_set CFBundleShortVersionString "${VERSION}"
plist_set CFBundleVersion "${BUILD}"

# Keep project.yml in lockstep. Without this, the next manual `xcodegen generate`
# would overwrite Info.plist with the previous (now-stale) version from project.yml,
# silently downgrading the bundle and breaking Sparkle's appcast comparison.
/usr/bin/sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]*\"/\1\"${VERSION}\"/" project.yml
/usr/bin/sed -i '' -E "s/(CFBundleVersion: )\"[^\"]*\"/\1\"${BUILD}\"/"             project.yml

# ───────────────────────── archive + export ─────────────────────────

say "Archive (Release)"
xcodebuild \
  -project Nod.xcodeproj \
  -scheme Nod \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
  DEVELOPMENT_TEAM=M44384588U >/dev/null

say "Export .app"
EXPORT_PLIST="${DIST_DIR}/export-options.plist"
cat > "${EXPORT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_PLIST}" >/dev/null

# ───────────────────────── DMG ─────────────────────────

say "Build DMG"
mkdir -p "${DMG_STAGE}"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"

hdiutil create \
  -volname "Nod" \
  -srcfolder "${DMG_STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

say "Sign DMG"
codesign --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

# ───────────────────────── notarize ─────────────────────────

if [ "$SKIP_NOTARIZE" = 1 ]; then
  say "Skipping notarization (--skip-notarize)"
  echo "    ⚠️  This DMG will trigger Gatekeeper warnings for any user other than you."
else
  say "Submit to notary service (blocks until Apple responds, ~30s–5min)"
  xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

  say "Staple notarization ticket"
  xcrun stapler staple "${DMG_PATH}"

  say "Verify"
  xcrun stapler validate "${DMG_PATH}"
  spctl --assess --type open --context context:primary-signature -v "${DMG_PATH}" 2>&1 \
    | grep -E "accepted|source=" || die "Gatekeeper assessment failed"
fi

# ───────────────────────── appcast ─────────────────────────

# generate_appcast hashes everything in DIST_DIR. Old release DMGs from previous
# runs would otherwise leak into the feed; stage only the current version's DMG
# in a clean sub-directory.
APPCAST_STAGE="${DIST_DIR}/appcast-stage"
rm -rf "${APPCAST_STAGE}"
mkdir -p "${APPCAST_STAGE}"
cp "${DMG_PATH}" "${APPCAST_STAGE}/"

say "Generate EdDSA-signed appcast"
"${SPARKLE_BIN_DIR}/generate_appcast" \
  --download-url-prefix "${APPCAST_BASE_URL}/" \
  -o "${APPCAST_PATH}" \
  "${APPCAST_STAGE}"

rm -rf "${APPCAST_STAGE}"

# Stable filename for the website download URL — copied AFTER appcast generation
# so generate_appcast doesn't see two archives with identical content.
cp "${DMG_PATH}" "${LATEST_DMG_PATH}"

# ───────────────────────── publish ─────────────────────────

if [ "$NO_PUBLISH" = 1 ]; then
  say "Skipping publish (--no-publish)"
  echo
  echo "Artifacts:"
  echo "  ${REPO_ROOT}/${DMG_PATH}"
  echo "  ${REPO_ROOT}/${LATEST_DMG_PATH}"
  echo "  ${REPO_ROOT}/${APPCAST_PATH}"
  exit 0
fi

say "Commit version bump"
git add Nod/Info.plist project.yml 2>/dev/null || true
if [ -n "$(git status --porcelain Nod/Info.plist)" ]; then
  git commit -m "release ${VERSION}" -- Nod/Info.plist
fi

say "Tag v${VERSION}"
git tag -a "v${VERSION}" -m "Nod ${VERSION}"

say "Push commits + tags to origin"
git push origin main
git push origin "v${VERSION}"

# GitHub Release exists for tag visibility + as an authenticated backup mirror
# of the binary (`gh release download`). The DMG attachment here is NOT what
# Sparkle downloads — Sparkle's URL points at Vercel below. This is just
# belt-and-braces: if nod-landing ever gets deleted, you can still pull DMGs
# out of GitHub with `gh` CLI.
say "Create GitHub Release"
RELEASE_NOTES_FLAG="--generate-notes"
[ -f CHANGELOG.md ] && RELEASE_NOTES_FLAG="--notes-file CHANGELOG.md"
gh release create "v${VERSION}" \
  "${DMG_PATH}" \
  "${LATEST_DMG_PATH}" \
  --title "Nod ${VERSION}" \
  ${RELEASE_NOTES_FLAG}

# Stage DMGs + appcast on nod-landing. Vercel serves /public/* as static
# files behind its public CDN, which is what Sparkle's HTTP client will hit.
say "Stage release on nod-landing"
mkdir -p "${NOD_LANDING_REPO}/public/dmg"
cp "${DMG_PATH}"        "${NOD_LANDING_REPO}/public/dmg/Nod-${VERSION}.dmg"
cp "${LATEST_DMG_PATH}" "${NOD_LANDING_REPO}/public/dmg/Nod-latest.dmg"
cp "${APPCAST_PATH}"    "${NOD_LANDING_REPO}/public/appcast.xml"
(
  cd "${NOD_LANDING_REPO}"
  git add public/appcast.xml public/dmg
  git commit -m "release ${VERSION}"
  git push
)

# ───────────────────────── deploy + verify live appcast ─────────────────────────

# Trigger the Vercel build ourselves instead of waiting for the GitHub
# integration. The integration has disconnected silently in the past (commits
# landing on origin but no new deployment building), which would mean every
# release after that point ships an appcast that never goes live — clients
# see "X is the newest" while running X+1.
say "Deploy nod-landing to Vercel (prod)"
(
  cd "${NOD_LANDING_REPO}"
  vercel deploy --prod --yes >/dev/null
)

# Even with an explicit deploy, the CDN edge needs a moment to switch the
# production alias. Both the appcast XML and the DMG it advertises have to be
# live before we can call the release done — otherwise Sparkle reads "X is
# available" and immediately fails to download X. Poll both, fail loudly
# after 3 min.
say "Wait for appcast + DMG ${VERSION} to go live"
APPCAST_URL="https://hellonod.app/appcast.xml"
DMG_URL="https://hellonod.app/dmg/Nod-${VERSION}.dmg"
DEADLINE=$(( $(date +%s) + 180 ))
APPCAST_OK=0
DMG_OK=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ "$APPCAST_OK" = 0 ] \
      && curl -fsSL "${APPCAST_URL}?v=$(date +%s)" 2>/dev/null \
        | grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"; then
    APPCAST_OK=1
  fi
  if [ "$DMG_OK" = 0 ]; then
    CODE=$(curl -sLo /dev/null -w "%{http_code}" "${DMG_URL}?v=$(date +%s)")
    [ "$CODE" = "200" ] && DMG_OK=1
  fi
  if [ "$APPCAST_OK" = 1 ] && [ "$DMG_OK" = 1 ]; then break; fi
  printf '.'
  sleep 5
done
echo
[ "$APPCAST_OK" = 1 ] || die "appcast ${VERSION} did not appear at ${APPCAST_URL} within 3 min — check Vercel deploys at https://vercel.com/dashboard"
[ "$DMG_OK"     = 1 ] || die "DMG did not appear at ${DMG_URL} within 3 min — check Vercel deploys at https://vercel.com/dashboard"
echo "    ✓ appcast live at ${APPCAST_URL}"
echo "    ✓ DMG live at     ${DMG_URL}"

# ───────────────────────── bump update gate ─────────────────────────

# The in-app UpdateGate nudge (the recommended-update banner) reads
# app_config.recommended_build — NOT the appcast. Bump it to this build so
# clients below it surface the nudge on next launch. Sparkle's own 24h check is
# independent and still works without this, but if the row goes stale the banner
# silently stops firing for everyone above the old threshold. Service-role only
# (app_config has no UPDATE policy); skipped with a warning if the key is absent
# so a release never hard-fails on it.
SUPABASE_API_URL="${SUPABASE_API_URL:-https://api.hellonod.app}"
if [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  say "Bump app_config.recommended_build → ${BUILD}"
  GATE_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X PATCH "${SUPABASE_API_URL}/rest/v1/app_config?singleton=eq.true" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"recommended_build\": ${BUILD}, \"updated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
  [ "$GATE_CODE" = "204" ] || die "app_config bump failed (HTTP ${GATE_CODE}) — recommended_build NOT updated"
  echo "    ✓ recommended_build = ${BUILD}"
else
  echo "    ⚠️  SUPABASE_SERVICE_ROLE_KEY not set — skipped app_config.recommended_build bump."
  echo "        The in-app update nudge won't track this release until you run:"
  echo "        update app_config set recommended_build = ${BUILD};"
fi

# ───────────────────────── done ─────────────────────────

echo
echo "🎉 Nod ${VERSION} (${BUILD}) released."
echo
echo "  DMG:     ${APPCAST_BASE_URL}/Nod-${VERSION}.dmg"
echo "  Latest:  https://hellonod.app/dmg/Nod-latest.dmg"
echo "  Appcast: https://hellonod.app/appcast.xml"
echo
echo "Installed clients will see the update on their next scheduled check (≤ 24h),"
echo "or immediately via status-bar menu → Check for Updates…"
