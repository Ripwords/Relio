#!/usr/bin/env bash
# Generates the Xcode project and builds the app for the iOS simulator.
# This is the gate every UI task runs: `swift test` cannot see SwiftUI, so the only
# automated proof the views compile and link is a real build.
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

if ! xcrun simctl list devices | grep -q "$DEVICE_NAME"; then
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
