#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA="/tmp/ProxyPilotDerived"

echo "Building Release to $DERIVED_DATA ..."
xcodebuild \
  -project ProxyPilot.xcodeproj \
  -scheme ProxyPilot-macOS \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  >/dev/null

APP_PATH="$DERIVED_DATA/Build/Products/Release/ProxyPilot.app"
echo "Built: $APP_PATH"

