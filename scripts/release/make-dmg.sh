#!/bin/bash
set -euo pipefail
# Packages build/release/zPDF.app into a drag-to-Applications disk image with create-dmg
# (https://github.com/create-dmg/create-dmg): a laid-out Finder window with the app beside an
# Applications link, the app's icon on the volume, and the image signed with Developer ID.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/release/zPDF.app"
VERSION="${1:-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)}"
DMG="$ROOT/build/release/zPDF-$VERSION.dmg"
STAGE="$ROOT/build/release/dmg-stage"
IDENTITY="${ZPDF_DMG_IDENTITY:-Developer ID Application}"
[ -d "$APP" ] || { echo "error: run scripts/release/build-app.sh first"; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg is required (brew install create-dmg)"; exit 1; }
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ICON=()
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ICON=(--volicon "$APP/Contents/Resources/AppIcon.icns")
# --skip-jenkins only when there's no GUI session to lay out the Finder window (CI, SSH).
LAYOUT=()
[ -n "${ZPDF_DMG_HEADLESS:-}" ] && LAYOUT=(--skip-jenkins)
create-dmg \
  --volname "zPDF $VERSION" "${ICON[@]}" \
  --window-pos 200 120 --window-size 540 360 --icon-size 112 --text-size 13 \
  --icon "zPDF.app" 140 170 --hide-extension "zPDF.app" \
  --app-drop-link 400 170 \
  --codesign "$IDENTITY" \
  --no-internet-enable "${LAYOUT[@]}" \
  "$DMG" "$STAGE"
rm -rf "$STAGE"
echo "==> Done: $DMG"
