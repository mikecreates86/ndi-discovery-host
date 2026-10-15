#!/bin/bash
# Builds "NDI Discovery Host.app" and a zip in ./build. Needs Xcode or the
# Command Line Tools (xcode-select --install). Builds for this Mac's chip.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
APP="build/NDI Discovery Host.app"

if ! command -v swift >/dev/null; then
  echo "Swift is not installed. Run: xcode-select --install   (one-time, free), then run this again."
  exit 1
fi

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/NDIDiscoveryHost" "$APP/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist.in > "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"          # ad-hoc signature
ditto -c -k --keepParent "$APP" "build/NDI-Discovery-Host-$VERSION.zip"

echo "Built: $APP"
echo "Zip:   build/NDI-Discovery-Host-$VERSION.zip"
