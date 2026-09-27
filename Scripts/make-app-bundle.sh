#!/bin/bash
# Builds ProSlide.app with `swift build` and assembles the bundle around the
# resulting executable. No Xcode project required, so this is the path CI and
# the install instructions both use.
#
#   ./Scripts/make-app-bundle.sh                 # release build -> build/ProSlide.app
#   ./Scripts/make-app-bundle.sh debug           # debug build
#   ./Scripts/make-app-bundle.sh --install       # release build, then copy to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ProSlide.app"
ICON_SRC="$ROOT/App/ProSlide/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
INSTALL_DIR="/Applications"

# Kept in sync with the Xcode project's build settings.
BUNDLE_ID="com.v3ndsxg.proslide"
VERSION="0.1.0"
BUILD_NUMBER="1"

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | cut -c 3-
}

die() { echo "error: $*" >&2; exit 1; }

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        release|Release)  CONFIG="release" ;;
        debug|Debug)      CONFIG="debug" ;;
        --install|-i)     INSTALL=1 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die "unknown option '$arg' (try --help)" ;;
        *)                die "unexpected argument '$arg' (config must come first, e.g. '$arg --install')" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "ProSlide.app can only be built on macOS"
command -v swift >/dev/null || die "swift not found; install Xcode or the Command Line Tools"
[ -f "$ROOT/Package.swift" ] || die "$ROOT/Package.swift not found"

echo "Building ProSlide ($CONFIG)…"
(cd "$ROOT" && swift build -c "$CONFIG")
# tail -1 because a stray diagnostic on stdout would otherwise corrupt the path
BIN_DIR="$(cd "$ROOT" && swift build -c "$CONFIG" --show-bin-path | tail -n 1)"
EXECUTABLE="$BIN_DIR/ProSlide"
[ -x "$EXECUTABLE" ] || die "expected an executable at $EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/ProSlide"

# The icon comes from the same 1024px PNG the asset catalog uses. iconutil and
# sips ship with macOS, so this needs no Xcode. A failure here is cosmetic --
# the app still runs with the generic icon.
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null && command -v sips >/dev/null; then
    ICONSET="$(mktemp -d)/ProSlide.iconset"
    mkdir -p "$ICONSET"
    # iconutil expects every standard representation; sips does the resampling.
    for pair in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
        px="${pair%%:*}"
        name="${pair##*:}.png"
        sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
    done
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/ProSlide.icns" 2>/dev/null; then
        echo "Generated ProSlide.icns"
    else
        echo "warning: iconutil failed; the app will use the generic icon" >&2
    fi
    rm -rf "$(dirname "$ICONSET")"
else
    echo "warning: no icon source at $ICON_SRC; the app will use the generic icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>ProSlide</string>
	<key>CFBundleExecutable</key>
	<string>ProSlide</string>
	<key>CFBundleIconFile</key>
	<string>ProSlide</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ProSlide</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# Every binary on Apple Silicon must be signed to run; ad-hoc is enough for a
# locally built app and matches CODE_SIGN_IDENTITY = "-" in the Xcode project.
if command -v codesign >/dev/null; then
    codesign --force --sign - --timestamp=none "$APP"
    echo "Signed $(codesign -dv "$APP" 2>&1 | sed -n 's/^ *Identifier=//p')"
else
    echo "warning: codesign not found; the app may refuse to launch" >&2
fi

if command -v plutil >/dev/null; then
    plutil -lint "$APP/Contents/Info.plist"
fi

if [ "$INSTALL" -eq 1 ]; then
    DEST="$INSTALL_DIR/ProSlide.app"
    rm -rf "$DEST" 2>/dev/null || true
    # ditto is part of base macOS and preserves the signature; cp is only a
    # fallback so a missing ditto is not a mysterious "command not found".
    # Whether this succeeds is the only reliable writability test -- an
    # access(2)-based `test -w` lies when the caller is root.
    if command -v ditto >/dev/null; then
        ditto "$APP" "$DEST" || die "could not write $DEST; if it is owned by another user try: sudo $0 $CONFIG --install"
    else
        cp -R "$APP" "$DEST" || die "could not write $DEST; if it is owned by another user try: sudo $0 $CONFIG --install"
    fi
    echo "Installed $DEST"
    echo "Launch it with:  open '$DEST'"
else
    echo
    echo "Built $APP"
    echo "Launch it with:  open '$APP'"
    echo "Install it with: $0 --install"
fi
