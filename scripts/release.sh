#!/usr/bin/env bash
# Nod release pipeline — build → sign → DMG → notarize → staple → appcast.
#
# Required env vars:
#   VERSION                   e.g. 0.0.2 (CFBundleShortVersionString)
#   BUILD                     e.g. 2     (CFBundleVersion, monotonic)
#   NOTARY_PROFILE            keychain profile name from `xcrun notarytool store-credentials`
#   SPARKLE_BIN_DIR           path to Sparkle distribution `bin/` (generate_appcast etc.)
#
# Optional:
#   APPCAST_BASE_URL          where the DMG will be hosted
#                             (default: https://github.com/dbarabashh/Nod/releases/download/v${VERSION})
#   SIGN_IDENTITY             Developer ID Application identity
#                             (default: "Developer ID Application")
#
# Output:
#   dist/Nod-${VERSION}.dmg   signed, notarized, stapled — upload to GitHub Releases
#   dist/appcast.xml          EdDSA-signed feed — copy to docs/appcast.xml on Pages

set -euo pipefail

cd "$(dirname "$0")/.."

: "${VERSION:?VERSION is required (e.g. 0.0.2)}"
: "${BUILD:?BUILD is required (monotonic integer)}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required (xcrun notarytool store-credentials profile name)}"
: "${SPARKLE_BIN_DIR:?SPARKLE_BIN_DIR is required (path to Sparkle bin/ with generate_appcast)}"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://github.com/dbarabashh/Nod/releases/download/v${VERSION}}"

DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/Nod-${VERSION}.xcarchive"
EXPORT_DIR="${DIST_DIR}/export"
APP_PATH="${EXPORT_DIR}/Nod.app"
DMG_STAGE="${DIST_DIR}/dmg-stage"
DMG_PATH="${DIST_DIR}/Nod-${VERSION}.dmg"
APPCAST_PATH="${DIST_DIR}/appcast.xml"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Guarding against placeholder Sparkle public key"
if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Nod/Info.plist | grep -q REPLACE_WITH_PUBLIC_ED_KEY; then
  echo "ERROR: SUPublicEDKey is still the placeholder. Run 'sparkle generate_keys' and update project.yml." >&2
  exit 1
fi

echo "==> Stamping version ${VERSION} (${BUILD})"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Nod/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" Nod/Info.plist

mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_STAGE}" "${DMG_PATH}"

echo "==> Archiving"
xcodebuild \
  -project Nod.xcodeproj \
  -scheme Nod \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"

echo "==> Exporting Developer ID-signed .app"
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
  -exportOptionsPlist "${EXPORT_PLIST}"

echo "==> Building DMG"
# Stage Nod.app + Applications symlink for the standard drag-to-install UX.
mkdir -p "${DMG_STAGE}"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"

hdiutil create \
  -volname "Nod" \
  -srcfolder "${DMG_STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "==> Signing DMG"
# DMG signature is independent of the .app signature. Both must be valid for
# Gatekeeper to accept the user-facing flow (mount → drag → launch).
codesign --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

echo "==> Submitting DMG to notary service (this blocks until Apple responds)"
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

echo "==> Stapling notarization ticket to DMG"
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying stapled DMG"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature -v "${DMG_PATH}" || true

# Unversioned copy so the website "Download for Mac" button can use
# https://github.com/<owner>/<repo>/releases/latest/download/Nod-latest.dmg
# as a permanent redirect — the filename has to be stable across releases.
LATEST_DMG_PATH="${DIST_DIR}/Nod-latest.dmg"
cp "${DMG_PATH}" "${LATEST_DMG_PATH}"

echo "==> Generating EdDSA-signed appcast"
# generate_appcast scans the directory and signs every .dmg/.zip it finds
# with the Sparkle key stored in the macOS Keychain.
"${SPARKLE_BIN_DIR}/generate_appcast" \
  --download-url-prefix "${APPCAST_BASE_URL}/" \
  -o "${APPCAST_PATH}" \
  "${DIST_DIR}"

echo
echo "Release ready:"
echo "  $(pwd)/${DMG_PATH}"
echo "  $(pwd)/${APPCAST_PATH}"
echo
RELEASE_NOTES_ARG="--generate-notes"
if [ -f CHANGELOG.md ]; then
  RELEASE_NOTES_ARG="--notes-file CHANGELOG.md"
fi

echo "Next:"
echo "  1. gh release create v${VERSION} ${DMG_PATH} ${LATEST_DMG_PATH} \\"
echo "       --title 'Nod ${VERSION}' ${RELEASE_NOTES_ARG}"
echo
echo "  2. Push appcast.xml to the nod-landing Vercel repo:"
echo "       cp ${APPCAST_PATH} <path-to-nod-landing>/public/appcast.xml"
echo "       cd <path-to-nod-landing>"
echo "       git commit -am 'appcast ${VERSION}'"
echo "       git push   # Vercel auto-deploys ~30s later"
echo
echo "Website download button URL (always-latest):"
echo "  https://github.com/dbarabashh/Nod/releases/latest/download/Nod-latest.dmg"
