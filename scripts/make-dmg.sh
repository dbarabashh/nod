#!/usr/bin/env bash
# Build a styled Nod install DMG: sky background, drag-to-Applications layout,
# 128px icons, hidden toolbar/sidebar, custom volume icon. Reusable by
# release.sh and for standalone previews.
#
#   scripts/make-dmg.sh <path/to/Nod.app> <path/to/out.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Nod.app> <out.dmg>}"
OUT="${2:?usage: make-dmg.sh <Nod.app> <out.dmg>}"
die() { echo "error: $*" >&2; exit 1; }
# Everything below follows the bundle it was handed rather than the name "Nod":
# the sandbox configuration builds "Nod Sandbox.app", and a volume named after
# the wrong app collides on the desktop the moment both are mounted.
APP_BUNDLE="$(basename "${APP}")"
VOL="${APP_BUNDLE%.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BG_TIFF="${HERE}/dmg/background.tiff"
[ -d "${APP}" ] || die "app bundle not found: ${APP}"
if ! ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist" 2>/dev/null)"; then
  die "${APP} has no CFBundleIconFile"
fi
ICON_NAME="${ICON_NAME%.icns}"
case "${ICON_NAME}" in
  AppIcon) VOLUME_ICON="${HERE}/dmg/volume-icon.icns" ;;
  AppIcon-Sandbox) VOLUME_ICON="${HERE}/dmg/volume-icon-sandbox.icns" ;;
  *) die "unsupported app icon ${ICON_NAME} in ${APP}" ;;
esac
[ -f "${BG_TIFF}" ] || die "DMG background not found: ${BG_TIFF}"
[ -f "${VOLUME_ICON}" ] || die "DMG volume icon not found: ${VOLUME_ICON}"
[ -x /usr/bin/SetFile ] || die "/usr/bin/SetFile is unavailable"
[ -x /usr/bin/GetFileInfo ] || die "/usr/bin/GetFileInfo is unavailable"

# ── layout (content window is 640×400 pt; matches background.tiff) ──
WIN_L=300 WIN_T=150 WIN_W=640 WIN_H=400
ICON_SIZE=128
NOD_X=165 NOD_Y=200
APP_X=475 APP_Y=200

WORK="$(mktemp -d)"
STAGE="${WORK}/stage"
RW="${WORK}/rw.dmg"
DEVICE=""
VERIFY_DEVICE=""
cleanup() {
  [ -z "${VERIFY_DEVICE}" ] || hdiutil detach "${VERIFY_DEVICE}" >/dev/null 2>&1 || true
  [ -z "${DEVICE}" ] || hdiutil detach "${DEVICE}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
mkdir -p "${STAGE}/.background"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
cp "${BG_TIFF}" "${STAGE}/.background/background.tiff"

# A leftover mount from a previous run would push our mount to "Nod 1" and
# desync every AppleScript reference — detach it first.
if [ -d "/Volumes/${VOL}" ]; then
  hdiutil detach "/Volumes/${VOL}" >/dev/null || die "could not detach existing /Volumes/${VOL}"
fi

hdiutil create -srcfolder "${STAGE}" -volname "${VOL}" -fs HFS+ -format UDRW -ov "${RW}" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW}")"
DEVICE="$(printf '%s\n' "${ATTACH_OUTPUT}" | awk '/^\/dev\// { print $1; exit }')"
[ -n "${DEVICE}" ] || die "could not determine device for ${RW}"
MOUNT="/Volumes/${VOL}"
sleep 1

osascript <<EOF
tell application "Finder"
  tell disk "${VOL}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {${WIN_L}, ${WIN_T}, $((WIN_L+WIN_W)), $((WIN_T+WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to ${ICON_SIZE}
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "${APP_BUNDLE}" of container window to {${NOD_X}, ${NOD_Y}}
    set position of item "Applications" of container window to {${APP_X}, ${APP_Y}}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

cp "${VOLUME_ICON}" "${MOUNT}/.VolumeIcon.icns"
/usr/bin/SetFile -a C "${MOUNT}"
VOLUME_ATTRIBUTES="$(/usr/bin/GetFileInfo -a "${MOUNT}")"
[[ "${VOLUME_ATTRIBUTES}" == *C* ]] || die "custom icon flag was not set on ${MOUNT}"
sync
[ -f "${MOUNT}/.VolumeIcon.icns" ] || die "mounted image is missing .VolumeIcon.icns"
cmp -s "${VOLUME_ICON}" "${MOUNT}/.VolumeIcon.icns" || die "mounted image contains the wrong volume icon"
hdiutil detach "${DEVICE}" >/dev/null
DEVICE=""
rm -f "${OUT}"
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -o "${OUT}" >/dev/null

VERIFY_MOUNT="${WORK}/verify"
mkdir -p "${VERIFY_MOUNT}"
ATTACH_OUTPUT="$(hdiutil attach -readonly -noverify -noautoopen -mountpoint "${VERIFY_MOUNT}" "${OUT}")"
VERIFY_DEVICE="$(printf '%s\n' "${ATTACH_OUTPUT}" | awk '/^\/dev\// { print $1; exit }')"
[ -n "${VERIFY_DEVICE}" ] || die "could not determine verification device for ${OUT}"
[ -f "${VERIFY_MOUNT}/.VolumeIcon.icns" ] || die "final DMG is missing .VolumeIcon.icns"
cmp -s "${VOLUME_ICON}" "${VERIFY_MOUNT}/.VolumeIcon.icns" || die "final DMG contains the wrong volume icon"
VOLUME_ATTRIBUTES="$(/usr/bin/GetFileInfo -a "${VERIFY_MOUNT}")"
[[ "${VOLUME_ATTRIBUTES}" == *C* ]] || die "final DMG is missing its custom icon flag"
hdiutil detach "${VERIFY_DEVICE}" >/dev/null
VERIFY_DEVICE=""
echo "built ${OUT}"
