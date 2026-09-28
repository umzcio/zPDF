#!/bin/bash
set -euo pipefail
# Packages build/release/zPDF.app into a branded drag-to-Applications disk image with
# create-dmg (https://github.com/create-dmg/create-dmg) and a background drawn by
# render-dmg-background.swift: the same installer design as zMeet and zStats. The image is
# signed with Developer ID (release.sh notarizes it).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/release/zPDF.app"
VERSION="${1:-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)}"
DMG="$ROOT/build/release/zPDF-$VERSION.dmg"
IDENTITY="${ZPDF_DMG_IDENTITY:-Developer ID Application}"
[ -d "$APP" ] || { echo "error: run scripts/release/build-app.sh first"; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg is required (brew install create-dmg)"; exit 1; }

STAGE="$(mktemp -d "$ROOT/build/release/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/zPDF.app"
ARTWORK="$ROOT/build/release/dmg-artwork"
mkdir -p "$ARTWORK"
swift "$ROOT/scripts/release/render-dmg-background.swift" "$ARTWORK/background.png"

# --skip-jenkins only when there's no GUI session to lay out the Finder window (CI, SSH).
# (macOS bash 3.2 with set -u needs the ${x[@]+...} form for a possibly empty array.)
LAYOUT=()
if [ -n "${ZPDF_DMG_HEADLESS:-}" ]; then LAYOUT=(--skip-jenkins); fi
rm -f "$DMG"
# Icon positions must match the arrow and label pills drawn in render-dmg-background.swift
# (app at x=200, Applications at x=520, y=218).
create-dmg \
  --volname "Install zPDF" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background "$ARTWORK/background.png" \
  --window-pos 240 180 --window-size 720 468 \
  --icon-size 112 --text-size 14 \
  --icon "zPDF.app" 200 218 --hide-extension "zPDF.app" \
  --app-drop-link 520 218 \
  --format UDZO --filesystem HFS+ \
  --codesign "$IDENTITY" \
  --no-internet-enable ${LAYOUT[@]+"${LAYOUT[@]}"} \
  "$DMG" "$STAGE" >/dev/null
echo "==> Done: $DMG"
