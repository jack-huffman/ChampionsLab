#!/bin/bash
#  Build "ChampionsLab.app" from the Swift sources in this directory.
#
#  Produces a universal (arm64 + x86_64) bundle that depends only on system
#  frameworks. The Regulation M-C dataset and its sprites are copied into
#  Resources/ at build time, so the app never touches the network — refreshing
#  the data is mkdata.py's job, not the app's.
#
#  Re-signing at the end matters: writing anything into a bundle invalidates
#  its signature, and macOS then refuses to launch it as "damaged".
#
#  Usage:  ./build.sh                 # build/reinstall into ~/Applications
#          ./build.sh /Applications   # or anywhere else
#          DEST=stage ./build.sh      # used by make-dmg.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="${1:-${DEST:-$HOME/Applications}}"
APP="$DEST_DIR/ChampionsLab.app"
VERSION="$(cat "$SRC_DIR/VERSION")"
MIN_MACOS="13.0"
BUILD="$SRC_DIR/build"

if [ ! -f "$SRC_DIR/data/champions.json" ]; then
	echo "error: data/champions.json is missing. Run ./mkdata.py first." >&2
	exit 1
fi

# Regenerate the icon if it's missing.
if [ ! -f "$SRC_DIR/AppIcon.icns" ]; then
	echo "==> generating icon"
	( cd "$SRC_DIR" && /usr/bin/python3 mkicon.py )
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
SDK="$(xcrun --show-sdk-path --sdk macosx)"
for arch in arm64 x86_64; do
	# -parse-as-library: @main lives in a file that isn't main.swift.
	swiftc -O -swift-version 5 -parse-as-library \
		-target "${arch}-apple-macosx${MIN_MACOS}" -sdk "$SDK" \
		-o "$BUILD/ChampionsLab-$arch" "$SRC_DIR"/*.swift
done
lipo -create -output "$BUILD/ChampionsLab" \
	"$BUILD/ChampionsLab-arm64" "$BUILD/ChampionsLab-x86_64"

echo "==> assembling bundle"
mkdir -p "$DEST_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ChampionsLab" "$APP/Contents/MacOS/ChampionsLab"
chmod +x "$APP/Contents/MacOS/ChampionsLab"
[ -f "$SRC_DIR/AppIcon.icns" ] && cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/"
cp "$SRC_DIR/data/champions.json" "$APP/Contents/Resources/champions.json"
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
