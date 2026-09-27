#!/bin/bash
# Wraps the SwiftPM executable in a real .app bundle so macOS treats it as a
# regular app: dock icon, menu bar, activation, and relaunching from Finder.
# Use this when running the bare target does not put a window on screen.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ProSlide"
DEST="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG" --product FileConverter

BINARY="$(swift build -c "$CONFIG" --product FileConverter --show-bin-path)/FileConverter"
[ -x "$BINARY" ] || { echo "error: no executable at $BINARY"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BINARY" "$DEST/Contents/MacOS/$APP_NAME"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.v3ndsxg.proslide</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$DEST" >/dev/null 2>&1 || echo "note: ad-hoc signing unavailable; the app still runs locally"

echo "Built $DEST"
echo "Run it with:  open '$DEST'"
