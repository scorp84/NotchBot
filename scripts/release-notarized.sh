#!/bin/bash
# Build a Developer ID disk image, submit it to Apple notarization, and staple the ticket.
# Usage: NOTCHBOT_NOTARY_PROFILE=YourProfile bash scripts/release-notarized.sh 1.2.0
#
# NOTCHBOT_NOTARY_PROFILE is a notarytool keychain profile for team 8QFBNKRSD7.
# Store one with: xcrun notarytool store-credentials
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?version, for example 1.2.0}"
IDENTITY="${NOTCHBOT_SIGN_IDENTITY:-Developer ID Application: Florian Kall (8QFBNKRSD7)}"
PROFILE="${NOTCHBOT_NOTARY_PROFILE:?Set NOTCHBOT_NOTARY_PROFILE to a notarytool keychain profile}"
KEYCHAIN="${NOTCHBOT_NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DMG="$ROOT/dist/NotchBot-${VERSION}.dmg"

if ! security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null; then
  echo "Missing signing identity: $IDENTITY" >&2
  exit 1
fi

export NOTCHBOT_SIGN_IDENTITY="$IDENTITY"
export NOTCHBOT_VERSION="$VERSION"

bash "$ROOT/build-app.sh" "$VERSION"
bash "$ROOT/scripts/make-dmg.sh" "$VERSION"

echo "Signing disk image..."
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

submit() {
  local target="$1"
  local log id
  echo "Submitting $(basename "$target") for notarization..."
  log="$(xcrun notarytool submit "$target" \
    --keychain-profile "$PROFILE" \
    --keychain "$KEYCHAIN" \
    --wait 2>&1)"
  printf '%s\n' "$log"
  if printf '%s\n' "$log" | grep -q "status: Accepted"; then
    return 0
  fi
  id="$(printf '%s\n' "$log" | awk '/^  id: /{print $2; exit}')"
  if [[ -n "$id" ]]; then
    xcrun notarytool log "$id" \
      --keychain-profile "$PROFILE" \
      --keychain "$KEYCHAIN" || true
  fi
  echo "Notarization was not accepted." >&2
  return 1
}

submit "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

(
  cd "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256"
)

MOUNT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT/NotchBot.app"
# Assessing the disk image itself returns "Insufficient Context" until a
# browser marks it quarantined. The app inside is the check that matters.
spctl --assess --type execute --verbose=2 "$MOUNT/NotchBot.app"

echo ""
echo "Notarized disk image: $DMG"
