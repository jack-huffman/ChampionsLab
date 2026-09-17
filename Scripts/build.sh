#!/bin/bash
#  Build "ChampionsLab.app" from the Swift sources in this directory.
#
#  Produces a universal (arm64 + x86_64) bundle that depends only on system
#  frameworks. The Regulation M-C dataset and its sprites are copied into
#  Resources/ at build time. The app can refresh the usage table over the
#  network from the Usage & Meta screen; the dex itself — forms, learnsets,
#  items, abilities — stays mkdata.py's job.
#
#  Re-signing at the end matters: writing anything into a bundle invalidates
#  its signature, and macOS then refuses to launch it as "damaged".
#
#  Usage:  ./Scripts/build.sh                 # build/reinstall into ~/Applications
#          ./Scripts/build.sh /Applications   # or anywhere else
#          DEST=stage ./Scripts/build.sh      # used by make-dmg.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-${DEST:-$HOME/Applications}}"
APP="$DEST_DIR/ChampionsLab.app"
VERSION="$(cat "$SRC_DIR/VERSION")"
MIN_MACOS="13.0"
BUILD="$SRC_DIR/build"

if [ ! -f "$SRC_DIR/data/champions.json" ]; then
	echo "error: data/champions.json is missing. Run ./Scripts/mkdata.py first." >&2
	exit 1
fi

# Regenerate the icon if it's missing.
if [ ! -f "$SRC_DIR/AppIcon.icns" ]; then
	echo "==> generating icon"
	( cd "$SRC_DIR" && /usr/bin/python3 Scripts/mkicon.py )
	rm -rf "$SRC_DIR/icon.iconset"; mkdir "$SRC_DIR/icon.iconset"
	for sz in 16 32 128 256 512; do
		sips -z $sz $sz "$SRC_DIR/icon-1024.png" \
			--out "$SRC_DIR/icon.iconset/icon_${sz}x${sz}.png" >/dev/null
		sips -z $((sz*2)) $((sz*2)) "$SRC_DIR/icon-1024.png" \
			--out "$SRC_DIR/icon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
	done
	iconutil -c icns "$SRC_DIR/icon.iconset" -o "$SRC_DIR/AppIcon.icns"
	rm -rf "$SRC_DIR/icon.iconset"
fi

echo "==> compiling (universal, macOS $MIN_MACOS+)"
mkdir -p "$BUILD"
# The package builds the binary: the library and the one-line executable
# that imports it, for both architectures in one go. This script only
# wraps the result in a bundle.
( cd "$SRC_DIR" && swift build -c release --arch arm64 --arch x86_64 \
	--product ChampionsLabApp 2>&1 | grep -E "error|warning: unre|Build complete" ) || true
BINARY="$SRC_DIR/.build/apple/Products/Release/ChampionsLabApp"
if [ ! -x "$BINARY" ]; then
	echo "error: swift build did not produce $BINARY" >&2
	exit 1
fi
cp "$BINARY" "$BUILD/ChampionsLab"

echo "==> assembling bundle"
mkdir -p "$DEST_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ChampionsLab" "$APP/Contents/MacOS/ChampionsLab"
chmod +x "$APP/Contents/MacOS/ChampionsLab"
[ -f "$SRC_DIR/AppIcon.icns" ] && cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/"
cp "$SRC_DIR/data/champions.json" "$APP/Contents/Resources/champions.json"
[ -f "$SRC_DIR/data/animations.json" ] && cp "$SRC_DIR/data/animations.json" "$APP/Contents/Resources/animations.json"
# Subdirectories, so Bundle.url(forResource:subdirectory:) can find them.
for set in sprites types items; do
	if [ -d "$SRC_DIR/data/$set" ]; then
		mkdir -p "$APP/Contents/Resources/$set"
		cp "$SRC_DIR/data/$set"/*.png "$APP/Contents/Resources/$set/" 2>/dev/null || true
	fi
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>                  <string>ChampionsLab</string>
	<key>CFBundleDisplayName</key>           <string>ChampionsLab</string>
	<key>CFBundleIdentifier</key>            <string>com.jackhuffman.championslab</string>
	<key>CFBundleExecutable</key>            <string>ChampionsLab</string>
	<key>CFBundleIconFile</key>              <string>AppIcon</string>
	<key>CFBundlePackageType</key>           <string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
	<key>CFBundleShortVersionString</key>    <string>$VERSION</string>
	<key>CFBundleVersion</key>               <string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key>     <string>public.app-category.games</string>
	<key>NSPrincipalClass</key>              <string>NSApplication</string>
	<key>NSHighResolutionCapable</key>       <true/>
	<key>NSLocalNetworkUsageDescription</key> <string>ChampionsLab finds other copies of the app on your network so you can battle the people running them.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_championslab._tcp</string>
	</array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing"
# Ad-hoc (`-`) because there's no Developer ID in the keychain. Enough to launch
# locally; see make-dmg.sh for what that means on another Mac.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> registering with LaunchServices"
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo
echo "built: $APP  ($(lipo -archs "$APP/Contents/MacOS/ChampionsLab"), v$VERSION)"
