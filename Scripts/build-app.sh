#!/usr/bin/env bash
# Generates the Xcode project and builds the app for the iOS simulator.
# This is the gate every UI task runs: `swift test` cannot see SwiftUI, so the only
# automated proof the views compile and link is a real build.
#
# Needs `sudo xcodebuild -runFirstLaunch` to have installed the simulator platform;
# without it, `xcodebuild` cannot enumerate simulator destinations at all. Once that has
# run, this is the real gate — prefer it over Scripts/typecheck-app.sh and
# Scripts/run-app.sh, which exist only for machines where it is blocked.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE_NAME="Relio Test Phone"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"

if [ ! -f Config/Signing.xcconfig ]; then
  echo "Config/Signing.xcconfig missing — copying the template."
  cp Config/Signing.example.xcconfig Config/Signing.xcconfig
fi

xcodegen generate

# The runtime is installed but this machine may have no devices created.
RUNTIME=$(xcrun simctl list runtimes --json \
  | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(sorted(rs, key=lambda r: r["version"])[-1]["identifier"])')

# A device with this name may already exist on some other, older runtime (e.g. left
# over from before a new simulator platform was installed) without existing on the
# current $RUNTIME — so the check must be scoped to $RUNTIME, not just the device name.
if ! xcrun simctl list devices --json \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['devices'].get('$RUNTIME', []); sys.exit(0 if any(x['name'] == '$DEVICE_NAME' for x in d) else 1)"; then
  echo "Creating simulator '$DEVICE_NAME' on $RUNTIME"
  xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME"
fi

xcodebuild \
  -project TaxTracker.xcodeproj \
  -scheme TaxTracker \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  -quiet \
  build

echo "Build succeeded."
