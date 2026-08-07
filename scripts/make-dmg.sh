#!/usr/bin/env bash
# Build a styled Nod install DMG: sky background, drag-to-Applications layout,
# 128px icons, hidden toolbar/sidebar, custom volume icon. Reusable by
# release.sh and for standalone previews.
#
#   scripts/make-dmg.sh <path/to/Nod.app> <path/to/out.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Nod.app> <out.dmg>}"
OUT="${2:?usage: make-dmg.sh <Nod.app> <out.dmg>}"
# Everything below follows the bundle it was handed rather than the name "Nod":
# the sandbox configuration builds "Nod Sandbox.app", and a volume named after
# the wrong app collides on the desktop the moment both are mounted.
APP_BUNDLE="$(basename "${APP}")"
VOL="${APP_BUNDLE%.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BG_TIFF="${HERE}/dmg/background.tiff"

# ── layout (content window is 640×400 pt; matches background.tiff) ──
WIN_L=300 WIN_T=150 WIN_W=640 WIN_H=400
ICON_SIZE=128
NOD_X=165 NOD_Y=200
APP_X=475 APP_Y=200

WORK="$(mktemp -d)"
STAGE="${WORK}/stage"
RW="${WORK}/rw.dmg"
mkdir -p "${STAGE}/.background"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
cp "${BG_TIFF}" "${STAGE}/.background/background.tiff"
# Brand the mounted volume's own icon with the app icon, if present. Which icns
# that is comes from the bundle — Sandbox builds ship AppIcon-Sandbox.icns.
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist" 2>/dev/null || echo AppIcon)"
cp "${APP}/Contents/Resources/${ICON_NAME}.icns" "${STAGE}/.VolumeIcon.icns" 2>/dev/null || true

# A leftover mount from a previous run would push our mount to "Nod 1" and
# desync every AppleScript reference — detach it first.
hdiutil detach "/Volumes/${VOL}" >/dev/null 2>&1 || true

hdiutil create -srcfolder "${STAGE}" -volname "${VOL}" -fs HFS+ -format UDRW -ov "${RW}" >/dev/null
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "${RW}" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/${VOL}"
sleep 1

# Custom-icon bit so Finder shows .VolumeIcon.icns for the mounted volume.
[ -f "${MOUNT}/.VolumeIcon.icns" ] && /usr/bin/SetFile -a C "${MOUNT}" 2>/dev/null || true

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

sync
hdiutil detach "${DEVICE}" >/dev/null
rm -f "${OUT}"
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -o "${OUT}" >/dev/null
rm -rf "${WORK}"
echo "built ${OUT}"
