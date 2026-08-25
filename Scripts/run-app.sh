#!/usr/bin/env bash
# Builds, installs and launches Relio on the iOS simulator WITHOUT xcodebuild.
#
# Why this exists: `xcodebuild` cannot enumerate simulator destinations on a machine whose
# Xcode first-launch component install has not run (it needs interactive admin auth), so
# Scripts/build-app.sh is unusable there. But `simctl` works, the iPhoneSimulator SDK is
# present, and SwiftPM can cross-compile the package — so the app bundle can be assembled
# by hand. This is what actually proved the app launches.
#
# It is NOT a replacement for a real Xcode build: no asset catalog compilation, no
# entitlements, no App Store packaging. Once `sudo xcodebuild -runFirstLaunch` has been
# run, prefer Scripts/build-app.sh.
#
# Usage: ./Scripts/run-app.sh [screenshot-path]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${RELIO_SIM_DEVICE:-Relio Test Phone}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
BUNDLE_ID="my.relio.TaxTracker"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.0-simulator"
STAGE="${TMPDIR:-/tmp}/relio-app-build"
APP="$STAGE/Relio.app"

if ! xcrun simctl list devices | grep -q "$DEVICE"; then
  RUNTIME=$(xcrun simctl list runtimes --json | python3 -c \
    'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(sorted(rs, key=lambda r: r["version"])[-1]["identifier"])')
  xcrun simctl create "$DEVICE" "$DEVICE_TYPE" "$RUNTIME"
fi
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true

# 1. Cross-compile the package for the simulator. Its .o files are genuine iOS objects
#    (LC_BUILD_VERSION platform 7); the "using sysroot for MacOSX" warning is cosmetic.
swift build --scratch-path .build-ios \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc "$TARGET" >/dev/null

# 2. Compile the app sources and link them against those objects.
rm -rf "$STAGE"; mkdir -p "$APP"
mapfile -t SOURCES < <(find App/TaxTracker -name '*.swift' | sort)
mapfile -t OBJS < <(find .build-ios/debug/TaxKit.build .build-ios/debug/TaxData.build \
                         .build-ios/debug/TaxPresentation.build -name '*.o' | sort)
xcrun swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -parse-as-library \
  -I .build-ios/debug/Modules -emit-executable -o "$APP/Relio" \
  "${SOURCES[@]}" "${OBJS[@]}" 2>&1 | grep -v "using sysroot" || true

# 3. Assemble the bundle. TaxKit reads its rulebooks through `Bundle.module`, whose
#    generated accessor looks in Bundle.main first — so the resource bundle must sit at
#    the .app root or every rulebook lookup fails at runtime.
cp -R .build-ios/debug/TaxKit_TaxKit.bundle "$APP/"
python3 - "$APP" <<'PY'
import plistlib, pathlib, sys
app = pathlib.Path(sys.argv[1])
pl = plistlib.loads(pathlib.Path("App/TaxTracker/Info.plist").read_bytes())
# Substitute what xcodebuild would have expanded from Config/Signing.xcconfig.
for k, v in list(pl.items()):
    if isinstance(v, str) and v.startswith("$("):
        pl[k] = "local" if "STORAGE_MODE" in v else ""
pl.update({"CFBundleExecutable": "Relio", "CFBundleIdentifier": "my.relio.TaxTracker",
           "CFBundleName": "Relio", "CFBundlePackageType": "APPL",
           "MinimumOSVersion": "26.0", "UIDeviceFamily": [1, 2],
           "DTPlatformName": "iphonesimulator", "LSRequiresIPhoneOS": True})
(app / "Info.plist").write_bytes(plistlib.dumps(pl))
PY
codesign --force --sign - "$APP" >/dev/null 2>&1

# 4. Install and launch.
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

if [ $# -ge 1 ]; then
  sleep 4
  xcrun simctl io "$DEVICE" screenshot "$1" >/dev/null
  echo "Screenshot: $1"
fi
