#!/bin/bash
# Pack dist/NotchBot.app into a drag-to-Applications disk image.
# Usage: bash scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${NOTCHBOT_VERSION:-1.0.0}}"
APP="$ROOT/dist/NotchBot.app"
OUT="$ROOT/dist/NotchBot-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run bash build-app.sh first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
MOUNT="$WORK/mnt"
RW_DMG="$WORK/rw.dmg"
mkdir -p "$STAGE" "$MOUNT"
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Copy the app ourselves. hdiutil -srcfolder follows the Applications symlink
# and would try to archive /Applications.
cp -R "$APP" "$STAGE/NotchBot.app"
ln -s /Applications "$STAGE/Applications"

APP_MB="$(du -sm "$STAGE" | awk '{print $1}')"
SIZE_MB="$((APP_MB + 24))"

hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "NotchBot" "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT" -nobrowse >/dev/null
cp -R "$STAGE/NotchBot.app" "$MOUNT/NotchBot.app"
ln -s /Applications "$MOUNT/Applications"
hdiutil detach "$MOUNT" >/dev/null

rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT" >/dev/null
shasum -a 256 "$OUT" | awk '{print $1 "  " $2}' > "${OUT}.sha256"

echo ""
echo "Disk image: $OUT"
echo "Checksum:   ${OUT}.sha256"
