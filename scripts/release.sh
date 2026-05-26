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
#   NOTARY_PROFILE      default: nod-notary  (skipped with --skip-notarize)
#   NOD_LANDING_REPO    default: $HOME/dev/nod-landing
#
# Optional:
#   SIGN_IDENTITY       default: "Developer ID Application"
#                       (override to "Nod Dev" + --skip-notarize for local tests)

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ───────────────────────── defaults / args ─────────────────────────

SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$HOME/Downloads/Sparkle-2.9.2/bin}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nod-notary}"
NOD_LANDING_REPO="${NOD_LANDING_REPO:-$HOME/dev/nod-landing}"
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
APPCAST_BASE_URL="https://github.com/dbarabashh/Nod/releases/download/v${VERSION}"

mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_STAGE}" "${DMG_PATH}" "${LATEST_DMG_PATH}"

# ───────────────────────── stamp version ─────────────────────────

say "Regenerate project"
xcodegen generate

say "Stamp ${VERSION} (${BUILD})"
plist_set CFBundleShortVersionString "${VERSION}"
plist_set CFBundleVersion "${BUILD}"

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

# Always make Nod-latest.dmg for the stable website download URL.
cp "${DMG_PATH}" "${LATEST_DMG_PATH}"

# ───────────────────────── appcast ─────────────────────────

say "Generate EdDSA-signed appcast"
"${SPARKLE_BIN_DIR}/generate_appcast" \
  --download-url-prefix "${APPCAST_BASE_URL}/" \
  -o "${APPCAST_PATH}" \
  "${DIST_DIR}"

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

say "Create GitHub Release"
RELEASE_NOTES_FLAG="--generate-notes"
[ -f CHANGELOG.md ] && RELEASE_NOTES_FLAG="--notes-file CHANGELOG.md"
gh release create "v${VERSION}" \
  "${DMG_PATH}" \
  "${LATEST_DMG_PATH}" \
  --title "Nod ${VERSION}" \
  ${RELEASE_NOTES_FLAG}

say "Push appcast.xml to nod-landing"
cp "${APPCAST_PATH}" "${NOD_LANDING_REPO}/public/appcast.xml"
(
  cd "${NOD_LANDING_REPO}"
  git add public/appcast.xml
  git commit -m "appcast ${VERSION}"
  git push
)

# ───────────────────────── done ─────────────────────────

echo
echo "🎉 Nod ${VERSION} (${BUILD}) released."
echo
echo "  DMG:     ${APPCAST_BASE_URL}/Nod-${VERSION}.dmg"
echo "  Latest:  https://github.com/dbarabashh/Nod/releases/latest/download/Nod-latest.dmg"
echo "  Appcast: https://nod-landing.vercel.app/appcast.xml  (Vercel deploys in ~30s)"
echo
echo "Installed clients will see the update on their next scheduled check (≤ 24h),"
echo "or immediately via status-bar menu → Check for Updates…"
