#!/bin/bash
set -euo pipefail
# Packages build/release/zPDF.app into a drag-to-Applications disk image.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/release/zPDF.app"
VERSION="${1:-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)}"
DMG="$ROOT/build/release/zPDF-$VERSION.dmg"
STAGE="$ROOT/build/release/dmg-stage"
[ -d "$APP" ] || { echo "error: run scripts/release/build-app.sh first"; exit 1; }
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "zPDF $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "Developer ID Application" --timestamp "$DMG"
echo "==> Done: $DMG"
