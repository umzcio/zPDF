#!/bin/bash
set -euo pipefail
# Builds a distributable zPDF.app: archive (Release) + Developer ID export, then
# verifies every nested binary (engine runtime included) is Developer ID signed
# with the hardened runtime, and that no debug entitlement remains.
# Output: build/release/zPDF.app
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/zPDF.xcarchive"
EXPORT="$OUT/export"
APP="$OUT/zPDF.app"
mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate --quiet)

echo "==> Archiving zPDF (Release)"
rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/zPDF.xcodeproj" -scheme zPDF -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" archive -quiet

echo "==> Exporting Developer ID app"
rm -rf "$EXPORT" "$APP"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/release/ExportOptions.plist" -quiet
cp -R "$EXPORT/zPDF.app" "$APP"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
INFO="$(codesign -dvv "$APP" 2>&1)"
case "$INFO" in *"Authority=Developer ID Application"*) ;; *) echo "error: not Developer ID signed"; exit 1 ;; esac
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "error: get-task-allow present (development signature)"; exit 1
fi
bad=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q "Mach-O" || continue
  d="$(codesign -dvv "$f" 2>&1 || true)"
  if ! grep -q "Authority=Developer ID Application" <<<"$d" || ! grep -q "flags=.*runtime" <<<"$d"; then
    echo "error: not Developer ID + hardened runtime: ${f#"$APP/"}"; bad=1
  fi
done < <(find "$APP/Contents/Resources/EngineRuntime" -type f -print0)
[ "$bad" = 0 ] || exit 1
echo "==> Done: $APP ($(defaults read "$APP/Contents/Info" CFBundleShortVersionString))"
