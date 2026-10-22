#!/bin/zsh
# Builds Headroom.app and the headroom command into ./build.
# Usage: scripts/build-app.sh [--install]
#   --install  copies Headroom.app to ~/Applications and the command to ~/.local/bin
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product HeadroomApp
swift build -c release --product headroom
BIN="$(swift build -c release --show-bin-path)"

APP="build/Headroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HeadroomApp" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/headroom" build/headroom

# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP and build/headroom"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications ~/.local/bin
  pkill -x Headroom 2>/dev/null || true
  rm -rf ~/Applications/Headroom.app
  cp -R "$APP" ~/Applications/Headroom.app
  cp build/headroom ~/.local/bin/headroom
  echo "Installed ~/Applications/Headroom.app and ~/.local/bin/headroom"
fi
