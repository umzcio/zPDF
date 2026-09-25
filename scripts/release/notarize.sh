#!/bin/bash
set -euo pipefail
# Notarizes a .dmg/.zip/.app with an App Store Connect API key and staples it.
# Credentials: scripts/release/.notary-config.local (gitignored) defining
# NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT="${1:?usage: notarize.sh <dmg|zip|app>}"
CONFIG="${NOTARY_CONFIG:-$ROOT/scripts/release/.notary-config.local}"
[ -f "$CONFIG" ] || { echo "error: $CONFIG not found"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
KEY_PATH="${NOTARY_KEY/#\~/$HOME}"
echo "==> Submitting $(basename "$ARTIFACT") to Apple notary service"
xcrun notarytool submit "$ARTIFACT" --key "$KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
echo "==> Stapling"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
