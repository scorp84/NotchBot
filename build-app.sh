#!/bin/bash
set -e

echo "Building NotchBot..."
swift build -c release 2>&1

APP_DIR="dist/NotchBot.app/Contents"
rm -rf dist
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp .build/release/NotchBot "$APP_DIR/MacOS/NotchBot"
cp NotchBot/Info.plist "$APP_DIR/Info.plist"

VERSION="${1:-${NOTCHBOT_VERSION:-1.0.0}}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP_DIR/Info.plist"
xcrun actool "NotchBot/Resources/AppIcon.icon" \
  --compile "$APP_DIR/Resources" \
  --app-icon AppIcon \
  --output-partial-info-plist /tmp/notchbot-icon.plist \
  --minimum-deployment-target 14.0 \
  --platform macosx \
  --target-device mac
codesign --force --sign - dist/NotchBot.app >/dev/null 2>&1 || true

echo ""
echo "NotchBot.app built successfully!"
echo "Location: dist/NotchBot.app"
echo "To run:   open dist/NotchBot.app"
