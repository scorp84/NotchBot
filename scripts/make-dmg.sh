#!/bin/bash
# Pack dist/NotchBot.app into a drag-to-Applications disk image.
# Usage: bash scripts/make-dmg.sh [version]
#
# The window layout matches scripts/dmg-background.png (760×500 points).
# Finder draws the real app icon and the Applications alias on top of that
# picture. Icon positions are the center of each icon.
#   NotchBot.app   (210, 248)
#   Applications   (550, 248)
# GitHub-hosted runners often cannot drive Finder. Styling is best-effort:
# if it fails, the script still writes a plain compressed image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${NOTCHBOT_VERSION:-1.0.0}}"
APP="$ROOT/dist/NotchBot.app"
OUT="$ROOT/dist/NotchBot-${VERSION}.dmg"
BACKGROUND="$ROOT/scripts/dmg-background.png"

WIN_X=160
WIN_Y=80
WIN_W=760
WIN_H=500
ICON_SIZE=128
APP_X=210
APP_Y=248
APPS_X=550
APPS_Y=248

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run bash build-app.sh first." >&2
  exit 1
fi
if [[ ! -f "$BACKGROUND" ]]; then
  echo "Missing $BACKGROUND." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/InstallerBackground.png" ]]; then
  echo "Missing the installer background inside $APP. Run bash build-app.sh first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW_DMG="$WORK/rw.dmg"
DEVICE=""
mkdir -p "$STAGE"

cleanup() {
  if [[ -n "${DEVICE}" ]]; then
    hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Copy the app ourselves. hdiutil -srcfolder follows the Applications symlink
# and would try to archive /Applications. ditto keeps the code signature.
ditto "$APP" "$STAGE/NotchBot.app"
ln -s /Applications "$STAGE/Applications"

APP_MB="$(du -sm "$STAGE" | awk '{print $1}')"
SIZE_MB="$((APP_MB + 24))"

if [[ -d /Volumes/NotchBot ]]; then
  echo "A volume named NotchBot is already mounted. Unmount it and run again." >&2
  exit 1
fi

hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "NotchBot" "$RW_DMG" >/dev/null
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\/NotchBot/ {print $1; exit}')"
MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\/NotchBot/ {print $NF; exit}')"
if [[ -z "$DEVICE" || -z "$MOUNT" ]]; then
  echo "Could not mount the disk image." >&2
  printf '%s\n' "$ATTACH_OUT" >&2
  exit 1
fi

ditto "$STAGE/NotchBot.app" "$MOUNT/NotchBot.app"
ln -s /Applications "$MOUNT/Applications"
# The picture lives inside the bundle. A sibling .background folder becomes
# an extra icon when Finder is set to show hidden files, and it covers the title.
# It is copied in before signing. Do not add it here: that would break the seal.
BACKGROUND_ON_VOLUME="$MOUNT/NotchBot.app/Contents/Resources/InstallerBackground.png"

style_finder_window() {
  local script="$WORK/style.applescript"
  cat > "$script" <<EOF
tell application "Finder"
  tell disk "NotchBot"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {${WIN_X}, ${WIN_Y}, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to ${ICON_SIZE}
    set text size of viewOptions to 13
    set background picture of viewOptions to POSIX file "${BACKGROUND_ON_VOLUME}"
    set position of item "NotchBot.app" of container window to {${APP_X}, ${APP_Y}}
    set position of item "Applications" of container window to {${APPS_X}, ${APPS_Y}}
    try
      set extension hidden of item "NotchBot.app" to true
    end try
    update without registering applications
    delay 1
    close
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {${WIN_X}, ${WIN_Y}, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to ${ICON_SIZE}
    set text size of viewOptions to 13
    set background picture of viewOptions to POSIX file "${BACKGROUND_ON_VOLUME}"
    set position of item "NotchBot.app" of container window to {${APP_X}, ${APP_Y}}
    set position of item "Applications" of container window to {${APPS_X}, ${APPS_Y}}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

  # Finder AppleScript needs a logged-in GUI. Headless runners time out or
  # refuse the event; the image is still published, just without this layout.
  if ! python3 - "$script" <<'PY'
import subprocess, sys
try:
    completed = subprocess.run(["osascript", sys.argv[1]], timeout=60)
except subprocess.TimeoutExpired:
    print("Finder styling timed out.", file=sys.stderr)
    sys.exit(1)
sys.exit(completed.returncode)
PY
  then
    echo "Finder could not style the window. Shipping the disk image without a custom layout." >&2
    return 0
  fi
}

style_finder_window
# Drop filesystem bookkeeping so it is not sealed into the image as an icon.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" "$MOUNT/.TemporaryItems"

# Finder writes .DS_Store when the window closes. Give it a moment to flush.
# Re-seal afterwards. Finder styling can touch the bundle, and the signature
# has to match the bytes that end up in the image.
sync
sleep 1
if [[ -n "${NOTCHBOT_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$NOTCHBOT_SIGN_IDENTITY" \
    "$MOUNT/NotchBot.app"
  codesign --verify --deep --strict --verbose=2 "$MOUNT/NotchBot.app"
fi

detached=0
for _ in 1 2 3 4 5 6; do
  if hdiutil detach "$DEVICE" >/dev/null; then
    detached=1
    DEVICE=""
    break
  fi
  sleep 1
done
if [[ "$detached" -ne 1 ]]; then
  hdiutil detach "$DEVICE" -force >/dev/null
  DEVICE=""
fi

rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT" >/dev/null
(
  cd "$(dirname "$OUT")"
  shasum -a 256 "$(basename "$OUT")"
) > "${OUT}.sha256"

echo ""
echo "Disk image: $OUT"
echo "Checksum:   ${OUT}.sha256"
