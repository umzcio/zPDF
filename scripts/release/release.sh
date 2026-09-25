#!/bin/bash
set -euo pipefail
# Local release build: tests -> Developer ID app -> DMG -> notarize -> staple ->
# signed Sparkle appcast. Publishing (tag, GitHub release, appcast commit) is a
# separate, explicit step printed at the end.
#   scripts/release/release.sh 0.1.0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:?usage: release.sh <version>}"
OUT="$ROOT/build/release"
APP="$OUT/zPDF.app"
DMG="$OUT/zPDF-$VERSION.dmg"
DIST="$OUT/dist"
PREFIX="https://github.com/umzcio/zPDF/releases/download/v$VERSION/"
SPARKLE_BIN="$OUT/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  echo "==> [1/5] Test suite"
  (cd "$ROOT" && xcodegen generate --quiet && xcodebuild -scheme zPDF -destination 'platform=macOS' test -quiet)
fi
echo "==> [2/5] Build + sign"
bash "$ROOT/scripts/release/build-app.sh"
BUILT="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
[ "$BUILT" = "$VERSION" ] || { echo "error: app is $BUILT; bump MARKETING_VERSION in project.yml"; exit 1; }

echo "==> [3/5] Notarize + staple the app, then package"
( cd "$OUT" && rm -f zPDF-notarize.zip && ditto -c -k --keepParent zPDF.app zPDF-notarize.zip )
bash "$ROOT/scripts/release/notarize.sh" "$OUT/zPDF-notarize.zip" || true   # zip can't be stapled; the app is
xcrun stapler staple "$APP"
bash "$ROOT/scripts/release/make-dmg.sh" "$VERSION"

echo "==> [4/5] Notarize + staple the DMG"
bash "$ROOT/scripts/release/notarize.sh" "$DMG"

echo "==> [5/5] Signed Sparkle appcast"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$DMG" "$DIST/"
[ -f "$ROOT/scripts/release/notes/$VERSION.html" ] && cp "$ROOT/scripts/release/notes/$VERSION.html" "$DIST/zPDF-$VERSION.html"
"$SPARKLE_BIN/generate_appcast" "$DIST" --download-url-prefix "$PREFIX" \
  --link "https://github.com/umzcio/zPDF" --maximum-deltas 0
cp "$DIST/appcast.xml" "$ROOT/appcast.xml"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo
echo "  DMG     : $DMG"
echo "  appcast : $ROOT/appcast.xml"
echo "  Publish : git tag v$VERSION && git push origin main v$VERSION"
echo "            gh release create v$VERSION \"$DMG\" --repo umzcio/zPDF --title \"zPDF $VERSION\" --notes-file scripts/release/notes/$VERSION.md"
echo "            git add appcast.xml && git commit -m \"appcast: $VERSION\" && git push"
