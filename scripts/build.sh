#!/bin/bash
# Builds "build/Flickdown.app" (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product Flickdown
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Flickdown"

APP="build/Flickdown.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flickdown"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/web "$APP/Contents/Resources/web"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
