#!/usr/bin/env bash
# Type-checks the SwiftUI app sources against the iOS simulator SDK.
#
# This exists because `xcodebuild` cannot enumerate simulator destinations on a machine
# whose Xcode first-launch component install has not run (it needs interactive admin
# auth). Type-checking needs only the SDK, which is present, so view code can still be
# verified to compile even when the full build gate cannot run.
#
# What this DOES catch: syntax errors, type errors, wrong or misspelled SwiftUI modifiers,
# actor-isolation and Sendable violations, and misuse of the package's own API.
# What it does NOT catch: linking, Info.plist and entitlement processing, asset
# compilation, and anything that only shows up when the app actually launches.
# `Scripts/build-app.sh` remains the real gate; this is the strongest check available
# while that one is blocked.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.0-simulator"

# The package must be built for iOS, not the host, or its .swiftmodule files are rejected.
swift build --scratch-path .build-ios \
  -Xswiftc -sdk -Xswiftc "$SDK" \
  -Xswiftc -target -Xswiftc "$TARGET" >/dev/null

mapfile -t SOURCES < <(find App/TaxTracker -name '*.swift' | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "No app sources found." >&2
  exit 1
fi

xcrun swiftc -typecheck \
  -sdk "$SDK" -target "$TARGET" -swift-version 6 \
  -I .build-ios/debug/Modules \
  "${SOURCES[@]}"

echo "Type-check succeeded (${#SOURCES[@]} files)."
