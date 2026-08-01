#!/usr/bin/env bash
# Nod release pipeline — turn-key.
#
# Usage:
#   ./scripts/release.sh patch              # 0.0.1 → 0.0.2
#   ./scripts/release.sh minor              # 0.0.1 → 0.1.0
#   ./scripts/release.sh major              # 0.0.1 → 1.0.0
#   ./scripts/release.sh 0.0.2              # explicit version
#
#   ./scripts/release.sh patch --channel beta --to a@x.com,b@y.com
#                                           # same build, but only accounts on the
#                                           # 'beta' channel are offered it
#   ./scripts/release.sh enroll   --channel beta --to c@z.com    # no build
#   ./scripts/release.sh unenroll --to c@z.com                   # no build
#
#   ./scripts/release.sh patch --feed beta   # private feed, for Macs whose build
#                                            # predates channel support
#
# Two ways to narrow the audience:
#
#   --channel  one feed, item tagged, membership decided server-side by account.
#              Nothing to do on the tester's Mac — but only builds that ship the
#              channel delegate can see tagged items, so this reaches a Mac only
#              once it is running such a build.
#   --feed     a separate feed file the tester's Mac is pointed at once, by hand.
#              Works with ANY build, including ones released before channels
#              existed, because overriding SUFeedURL is core Sparkle behaviour.
#
# Flags:
#   --channel NAME    tag the appcast item with <sparkle:channel>NAME</sparkle:channel>.
#                     Only clients whose account is on that channel can see it —
#                     everyone else keeps being offered the newest untagged build.
#                     Skips the app_config nudge, the website's Nod-latest.dmg,
#                     and marks the GitHub release as a prerelease.
#   --feed NAME       publish into public/appcast-NAME.xml instead of the public
#                     feed, leaving appcast.xml untouched. A new private feed is
#                     seeded from the public one so the Mac reading it keeps every
#                     build it already had; later general releases are written into
#                     every private feed too, so nobody gets stranded on one.
#   --to EMAILS       comma-separated accounts to put on --channel before building.
#                     A single unknown address aborts the release before it builds.
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
CHANNEL=""
FEED_NAME=""
TO_EMAILS=""

usage() {
  sed -n '2,/^set -euo/p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-publish)    NO_PUBLISH=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --channel)       shift; CHANNEL="${1:-}" ;;
    --feed)          shift; FEED_NAME="${1:-}" ;;
    --to)            shift; TO_EMAILS="${1:-}" ;;
    -h|--help)       usage ;;
    *)               VERSION_ARG="$1" ;;
  esac
  shift
done

[ -n "$VERSION_ARG" ] || { echo "ERROR: version arg required (patch/minor/major, X.Y.Z, enroll or unenroll)" >&2; usage; }
[ -z "$TO_EMAILS" ] || [ -n "$CHANNEL" ] || [ "$VERSION_ARG" = "unenroll" ] \
  || { echo "ERROR: --to needs --channel (which channel are they joining?)" >&2; usage; }

# Both flags narrow the audience, and everything that must not happen for a
# narrow release — moving the website's download, nudging the whole install base,
# claiming /releases/latest — is the same either way.
LIMITED=""
if [ -n "$CHANNEL" ] || [ -n "$FEED_NAME" ]; then LIMITED="yes"; fi

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

SUPABASE_API_URL="${SUPABASE_API_URL:-https://api.hellonod.app}"

# ───────────────────────── channel membership ─────────────────────────

# Who may see a channel lives in the database, not in the feed: Sparkle asks the
# client which channels it is allowed to look in, so membership has to reach the
# app before it ever fetches the appcast. Service-role only — the client can read
# its own row and nothing else.
supabase_rpc() { # $1 function, $2 JSON body
  [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] \
    || die "SUPABASE_SERVICE_ROLE_KEY not set — channel membership is service-role only"
  curl -sS -X POST "${SUPABASE_API_URL}/rest/v1/rpc/$1" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2"
}

emails_json() { # a@x.com,b@y.com → ["a@x.com","b@y.com"]
  printf '[%s]' "$(echo "$1" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
    | sed 's/.*/"&"/' | paste -sd, -)"
}

enrol_emails() { # $1 channel, $2 emails
  say "Put ${2} on the '${1}' channel"
  ENROL_RESPONSE=$(supabase_rpc set_release_channel \
    "{\"p_emails\": $(emails_json "$2"), \"p_channel\": \"$1\"}")
  echo "$ENROL_RESPONSE" | grep -q '"enrolled":true' \
    || die "set_release_channel enrolled nobody: ${ENROL_RESPONSE}"
  if echo "$ENROL_RESPONSE" | grep -q '"enrolled":false'; then
    echo "$ENROL_RESPONSE" | tr '}' '\n' | grep '"enrolled":false' \
      | sed -E 's/.*"input_email":"([^"]+)".*/      ✗ \1/'
    die "no Nod account uses the address(es) above — fix the typo before shipping a build nobody can see"
  fi
  echo "$ENROL_RESPONSE" | tr '}' '\n' | grep '"enrolled":true' \
    | sed -E 's/.*"input_email":"([^"]+)".*/      ✓ \1/'
}

unenrol_emails() { # $1 emails
  say "Take ${1} off their release channel"
  echo "    rows removed: $(supabase_rpc clear_release_channel "{\"p_emails\": $(emails_json "$1")}")"
}

case "$VERSION_ARG" in
  enroll)
    [ -n "$CHANNEL" ] && [ -n "$TO_EMAILS" ] || die "enroll needs both --channel and --to"
    enrol_emails "$CHANNEL" "$TO_EMAILS"
    echo
    echo "They see '${CHANNEL}' builds from the next launch onwards — the app caches"
    echo "its channel at startup, so an app that never runs never joins."
    exit 0
    ;;
  unenroll)
    [ -n "$TO_EMAILS" ] || die "unenroll needs --to"
    unenrol_emails "$TO_EMAILS"
    echo
    echo "This is not a downgrade: a tester already on a newer build stays on it"
    echo "until the default channel catches up. Sparkle never moves anyone back."
    exit 0
    ;;
esac

# The next build has to clear EVERY item in the feed, not just the one stamped in
# Info.plist. A channel release bumps the feed without touching the working tree,
# so a later default release numbered from Info.plist alone would come out older
# than the outstanding beta — and the testers on it would never be offered it.
feed_max_build() {
  local xml=""
  # Every feed counts, private ones included: a build handed to one tester
  # through appcast-beta.xml still has to be outranked by the next general one.
  if ls "${NOD_LANDING_REPO}"/public/appcast*.xml >/dev/null 2>&1; then
    xml=$(cat "${NOD_LANDING_REPO}"/public/appcast*.xml)
  else
    xml=$(curl -fsSL "https://hellonod.app/appcast.xml" 2>/dev/null || true)
  fi
  {
    printf '%s' "$xml" | grep -oE 'sparkle:version="[0-9]+"' || true
    printf '%s' "$xml" | grep -oE '<sparkle:version>[0-9]+<' || true
  } | grep -oE '[0-9]+' | sort -n | tail -1
}

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

# `|| true` because `set -o pipefail` turns "no feed reachable" (offline, or a
# machine without the landing repo checked out) into a failed pipeline, and a
# missing feed is a fallback case, not an error.
FEED_BUILD="$(feed_max_build || true)"
FEED_BUILD="${FEED_BUILD:-0}"
BUILD=$(( (CURRENT_BUILD > FEED_BUILD ? CURRENT_BUILD : FEED_BUILD) + 1 ))

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
echo "    Next:    ${VERSION} (${BUILD})   [feed high-water mark: ${FEED_BUILD}]"
echo "    Channel: $([ -n "$CHANNEL" ] && echo "${CHANNEL} — only enrolled accounts" || echo 'default — everyone')"
echo "    Sign:    $SIGN_IDENTITY"
echo "    Notarize: $([ "$SKIP_NOTARIZE" = 1 ] && echo 'SKIPPED' || echo "$NOTARY_PROFILE")"
echo "    Publish: $([ "$NO_PUBLISH" = 1 ] && echo 'SKIPPED' || echo "GitHub + $NOD_LANDING_REPO")"
[ "$DRY_RUN" = 1 ] && { echo "    [dry-run mode — exiting]"; exit 0; }
echo

# Enrol before building, not after: a typo'd address should cost seconds rather
# than a full notarised build that nobody is allowed to download.
if [ -n "$TO_EMAILS" ]; then
  enrol_emails "$CHANNEL" "$TO_EMAILS"
  echo
fi

# ───────────────────────── paths ─────────────────────────

DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/Nod-${VERSION}.xcarchive"
EXPORT_DIR="${DIST_DIR}/export"
APP_PATH="${EXPORT_DIR}/Nod.app"
DMG_PATH="${DIST_DIR}/Nod-${VERSION}.dmg"
LATEST_DMG_PATH="${DIST_DIR}/Nod-latest.dmg"
# Feed filenames are decided later (a run may write more than one); dist/ just
# mirrors whatever gets published.
# DMGs are served from Vercel rather than GitHub release assets: the source
# repo is private, so GitHub's release-download URLs return 404 to unauthenticated
# clients — and Sparkle is an unauthenticated client. nod-landing/public/dmg/
# is public via Vercel CDN, so the URL Sparkle resolves actually serves bytes.
APPCAST_BASE_URL="https://hellonod.app/dmg"

mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_PATH}" "${LATEST_DMG_PATH}"

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

say "Build DMG (styled: sky background, drag-to-Applications layout)"
run "./scripts/make-dmg.sh '${APP_PATH}' '${DMG_PATH}'"

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

# generate_appcast extends the appcast it is pointed at and keeps the items
# already in it — including items whose DMG is long gone from the staging
# directory, which is why only the new archive is staged here.
#
# The base is the PUBLISHED feed, not whatever `dist/appcast.xml` this machine
# happens to hold. With two tracks in one feed that stops mattering only in
# theory: release a beta from a laptop whose dist/ predates the last stable
# release and the stable item would vanish for all 20 users.
#
# `Nod-latest.dmg` is deliberately not staged either: byte-identical to the
# versioned DMG, it would come back as a duplicate item for the same version.
# Which feed files this build lands in. A --feed run touches ONLY its own file,
# so the public feed — and therefore every client that never asked for a private
# one — is left exactly as it was. A normal release lands in the public feed and
# in every private feed that exists, which is what keeps a Mac parked on a
# private feed from missing general releases forever.
if [ -n "$FEED_NAME" ]; then
  TARGET_FEEDS=("appcast-${FEED_NAME}.xml")
else
  TARGET_FEEDS=("appcast.xml")
  for existing in "${NOD_LANDING_REPO}"/public/appcast-*.xml; do
    if [ -f "$existing" ]; then
      TARGET_FEEDS+=("$(basename "$existing")")
    fi
  done
fi

APPCAST_STAGE="${DIST_DIR}/appcast-stage"
PUBLISHED_FEEDS=()

for feed in "${TARGET_FEEDS[@]}"; do
  rm -rf "${APPCAST_STAGE}"
  mkdir -p "${APPCAST_STAGE}"

  # Seed order matters. A private feed that does not exist yet starts from the
  # public one, so the Mac pointed at it keeps every build it was already
  # entitled to instead of being cut down to this single item.
  if [ -f "${NOD_LANDING_REPO}/public/${feed}" ]; then
    cp "${NOD_LANDING_REPO}/public/${feed}" "${APPCAST_STAGE}/${feed}"
  elif [ -f "${NOD_LANDING_REPO}/public/appcast.xml" ]; then
    cp "${NOD_LANDING_REPO}/public/appcast.xml" "${APPCAST_STAGE}/${feed}"
  elif [ -f "${DIST_DIR}/${feed}" ]; then
    cp "${DIST_DIR}/${feed}" "${APPCAST_STAGE}/${feed}"
  fi

  cp "${DMG_PATH}" "${APPCAST_STAGE}/"

  if [ -f "${APPCAST_STAGE}/${feed}" ]; then
    say "Generate ${feed} (${BUILD})${CHANNEL:+ [channel: ${CHANNEL}]} — extending $(grep -c '<item>' "${APPCAST_STAGE}/${feed}" || echo 0) item(s)"
  else
    say "Generate ${feed} (${BUILD}) — fresh single-item feed"
  fi

  # --versions pins new-item generation to this build so the carried-over items
  # are left exactly as published; --channel is what makes an item invisible to
  # everyone who is not enrolled. Deltas are off because only one archive is ever
  # staged, so a delta item would reference a file this script never publishes.
  "${SPARKLE_BIN_DIR}/generate_appcast" \
    --download-url-prefix "${APPCAST_BASE_URL}/" \
    --versions "${BUILD}" \
    --maximum-versions 3 \
    --maximum-deltas 0 \
    ${CHANNEL:+--channel "${CHANNEL}"} \
    -o "${APPCAST_STAGE}/${feed}" \
    "${APPCAST_STAGE}"

  cp "${APPCAST_STAGE}/${feed}" "${DIST_DIR}/${feed}"
  PUBLISHED_FEEDS+=("${feed}")

  grep -q "<sparkle:version>${BUILD}</sparkle:version>\|sparkle:version=\"${BUILD}\"" "${DIST_DIR}/${feed}" \
    || die "${feed} has no item for build ${BUILD} — refusing to publish"
  if [ -n "$CHANNEL" ]; then
    grep -q "<sparkle:channel>${CHANNEL}</sparkle:channel>" "${DIST_DIR}/${feed}" \
      || die "build ${BUILD} was not tagged into the '${CHANNEL}' channel in ${feed} — it would ship to everyone"
  fi
done
rm -rf "${APPCAST_STAGE}"

# Stable filename for the website download button. A channel build must never
# become it: that URL is what hellonod.app hands anyone who clicks Download.
if [ -z "$LIMITED" ]; then
  cp "${DMG_PATH}" "${LATEST_DMG_PATH}"
fi

# ───────────────────────── publish ─────────────────────────

if [ "$NO_PUBLISH" = 1 ]; then
  say "Skipping publish (--no-publish)"
  echo
  echo "Artifacts:"
  echo "  ${REPO_ROOT}/${DMG_PATH}"
  if [ -z "$LIMITED" ]; then echo "  ${REPO_ROOT}/${LATEST_DMG_PATH}"; fi
  for feed in "${PUBLISHED_FEEDS[@]}"; do echo "  ${REPO_ROOT}/${DIST_DIR}/${feed}"; done
  exit 0
fi

say "Commit version bump"
# Stamp both files (Info.plist + project.yml, kept in lockstep above) into ONE
# commit and push it. Committing only Info.plist used to leave project.yml's bump
# staged-but-uncommitted forever, tripping the next run's clean-tree check.
git add Nod/Info.plist project.yml 2>/dev/null || true
if [ -n "$(git status --porcelain Nod/Info.plist project.yml)" ]; then
  git commit -m "release ${VERSION}" -- Nod/Info.plist project.yml
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
# A channel build is attached alone and marked prerelease: GitHub excludes
# prereleases from /releases/latest, so the website's download link keeps
# resolving to the last build everyone is allowed to have.
if [ -n "$LIMITED" ]; then
  gh release create "v${VERSION}" \
    "${DMG_PATH}" \
    --title "Nod ${VERSION} (${CHANNEL:-$FEED_NAME})" \
    --prerelease \
    ${RELEASE_NOTES_FLAG}
else
  gh release create "v${VERSION}" \
    "${DMG_PATH}" \
    "${LATEST_DMG_PATH}" \
    --title "Nod ${VERSION}" \
    ${RELEASE_NOTES_FLAG}
fi

# Stage DMGs + appcast on nod-landing. Vercel serves /public/* as static
# files behind its public CDN, which is what Sparkle's HTTP client will hit.
say "Stage release on nod-landing"
mkdir -p "${NOD_LANDING_REPO}/public/dmg"
cp "${DMG_PATH}"        "${NOD_LANDING_REPO}/public/dmg/Nod-${VERSION}.dmg"
if [ -z "$LIMITED" ]; then
  cp "${LATEST_DMG_PATH}" "${NOD_LANDING_REPO}/public/dmg/Nod-latest.dmg"
fi
for feed in "${PUBLISHED_FEEDS[@]}"; do
  cp "${DIST_DIR}/${feed}" "${NOD_LANDING_REPO}/public/${feed}"
done
(
  cd "${NOD_LANDING_REPO}"
  git add public/appcast*.xml public/dmg
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
# Poll the feed this build actually landed in — for a --feed run that is the
# private one, and appcast.xml will (correctly) never mention this version.
PRIMARY_FEED="${PUBLISHED_FEEDS[0]}"
APPCAST_URL="https://hellonod.app/${PRIMARY_FEED}"
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
#
# A channel build must never move it. The banner has no notion of channels, so
# raising it to a beta build would nag all 20 default-channel users toward a
# build Sparkle will correctly refuse to offer them.
if [ -n "$LIMITED" ]; then
  say "Leaving app_config.recommended_build alone (channel release)"
elif [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
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
if [ -n "$CHANNEL" ]; then
  echo "🎉 Nod ${VERSION} (${BUILD}) released on the '${CHANNEL}' channel."
elif [ -n "$FEED_NAME" ]; then
  echo "🎉 Nod ${VERSION} (${BUILD}) released to the '${FEED_NAME}' feed."
else
  echo "🎉 Nod ${VERSION} (${BUILD}) released."
fi
echo
echo "  DMG:     ${APPCAST_BASE_URL}/Nod-${VERSION}.dmg"
if [ -z "$LIMITED" ]; then echo "  Latest:  https://hellonod.app/dmg/Nod-latest.dmg"; fi
for feed in "${PUBLISHED_FEEDS[@]}"; do echo "  Appcast: https://hellonod.app/${feed}"; done
echo
if [ -n "$CHANNEL" ]; then
  echo "Only accounts on '${CHANNEL}' are offered this build. Everyone else stays on"
  echo "the newest default-channel build, and the next default release (which will be"
  echo "numbered above ${BUILD}) pulls the channel back in automatically."
  echo
fi
if [ -n "$FEED_NAME" ]; then
  echo "Nothing changed for anyone still on the public feed. To hand this build to a"
  echo "Mac, run this once on it — Sparkle then downloads and installs it the same"
  echo "way it does any update:"
  echo
  echo "  defaults write com.example.nod SUFeedURL \"https://hellonod.app/appcast-${FEED_NAME}.xml\""
  echo
  echo "Quit Nod first: a running app caches its preferences domain. To put that Mac"
  echo "back on the public feed later: defaults delete com.example.nod SUFeedURL"
  echo
fi
echo "Installed clients will see the update on their next scheduled check (≤ 24h),"
echo "or immediately via status-bar menu → Check for Updates…"
