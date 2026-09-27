#!/bin/bash
# Builds ProSlide.app from the Xcode project and copies it somewhere you can
# double-click. Use this when you want a standalone app without opening Xcode;
# the product is byte-for-byte what Xcode's Cmd-B produces.
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/App/ProSlide.xcodeproj"
SCHEME="ProSlide"
DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/build/ProSlide.app"

[ -d "$PROJECT" ] || { echo "error: $PROJECT not found"; exit 1; }

echo "Building $SCHEME ($CONFIG)…"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    build

BUILT="$DERIVED/Build/Products/$CONFIG/ProSlide.app"
[ -d "$BUILT" ] || { echo "error: expected $BUILT"; exit 1; }

rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
cp -R "$BUILT" "$APP"

echo
echo "Built $APP"
echo "Launch it with:  open '$APP'"
echo "Install it with: cp -R '$APP' /Applications/"
