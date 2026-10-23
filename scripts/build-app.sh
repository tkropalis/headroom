#!/bin/zsh
# Builds Headroom.app and the headroom command into ./build.
# Usage: scripts/build-app.sh [--install] [--release]
#   --install  copies Headroom.app to ~/Applications and the command to ~/.local/bin
#   --release  signs with Developer ID and hardened runtime, notarizes, staples, and
#              writes build/Headroom.zip to share. Needs once:
#                xcrun notarytool store-credentials headroom-notary \
#                  --apple-id <apple id> --team-id <team id> --password <app-specific password>
#              HEADROOM_SIGN_IDENTITY picks the certificate when there's more than one;
#              HEADROOM_NOTARY_PROFILE names another notarytool profile.
set -euo pipefail

INSTALL=false
RELEASE=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --release) RELEASE=true ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

cd "$(dirname "$0")/.."

# Check release signing before building, so a missing certificate fails fast.
if $RELEASE; then
  PROFILE="${HEADROOM_NOTARY_PROFILE:-headroom-notary}"
  IDENTITY="${HEADROOM_SIGN_IDENTITY:-}"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITIES=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')}")
    IDENTITIES=(${IDENTITIES:#})
    if (( ${#IDENTITIES} == 0 )); then
      echo "No Developer ID Application certificate in the keychain." >&2
      echo "Create one at developer.apple.com (Certificates, Developer ID Application) and install it." >&2
      exit 1
    elif (( ${#IDENTITIES} > 1 )); then
      echo "More than one Developer ID certificate; set HEADROOM_SIGN_IDENTITY to one of:" >&2
      printf '  %s\n' "${IDENTITIES[@]}" >&2
      exit 1
    fi
    IDENTITY="${IDENTITIES[1]}"
  fi
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No working notarytool profile named $PROFILE. Store one with:" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id <team id> --password <app-specific password>" >&2
    exit 1
  fi
  echo "Signing with $IDENTITY"
fi

swift build -c release --product HeadroomApp
swift build -c release --product headroom
BIN="$(swift build -c release --show-bin-path)"

APP="build/Headroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HeadroomApp" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/headroom" build/headroom

if $RELEASE; then
  # Hardened runtime and a secure timestamp are what notarization asks for.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" build/headroom
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  # The app and the command go up together; only the app can carry a stapled ticket.
  SUBMIT="build/notarize.zip"
  rm -f "$SUBMIT"
  STAGE="$(mktemp -d)"
  cp -R "$APP" build/headroom "$STAGE/"
  ditto -c -k "$STAGE" "$SUBMIT"
  rm -rf "$STAGE"
  echo "Notarizing; this usually takes a few minutes"
  if ! xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --timeout 30m; then
    echo "Notarization failed. For the reasons: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
    exit 1
  fi
  rm -f "$SUBMIT"

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"

  rm -f build/Headroom.zip
  ditto -c -k --keepParent "$APP" build/Headroom.zip
  echo "Built, notarized and stapled $APP; share build/Headroom.zip"
else
  # Ad-hoc signature: enough to run on this Mac.
  codesign --force --sign - --timestamp=none "$APP"
  echo "Built $APP and build/headroom"
fi

if $INSTALL; then
  mkdir -p ~/Applications ~/.local/bin
  pkill -x Headroom 2>/dev/null || true
  rm -rf ~/Applications/Headroom.app
  cp -R "$APP" ~/Applications/Headroom.app
  cp build/headroom ~/.local/bin/headroom
  echo "Installed ~/Applications/Headroom.app and ~/.local/bin/headroom"
fi
