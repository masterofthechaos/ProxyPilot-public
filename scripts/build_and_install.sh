#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA="/tmp/ProxyPilotDerived"
APP_PATH="$DERIVED_DATA/Build/Products/Release/ProxyPilot.app"
DEST="/Applications/ProxyPilot.app"

# 1. Regenerate Xcode project (picks up new/removed files)
echo "Regenerating Xcode project..."
zsh scripts/update_xcodeproj.sh

# 2. Build Release
echo "Building Release..."
xcodebuild \
  -project ProxyPilot.xcodeproj \
  -scheme ProxyPilot-macOS \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  2>&1 | tail -1

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: Missing build output: $APP_PATH" >&2
  exit 1
fi

# 3. Read version from built app
NEW_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
NEW_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist")

# 4. Quit running instance if present
if pgrep -xq "ProxyPilot"; then
  echo "Stopping running ProxyPilot..."
  killall ProxyPilot 2>/dev/null || true
  sleep 1
fi

# 5. Install to /Applications
echo "Installing to $DEST ..."
rm -rf "$DEST"
ditto "$APP_PATH" "$DEST"

echo "Installed ProxyPilot v${NEW_VER} (build ${NEW_BUILD}) to $DEST"
