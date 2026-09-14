#!/bin/bash
#  Package ChampionsLab.app into an installable disk image.
#
#  The app links only against system frameworks and carries its Regulation M-C
#  dataset inside the bundle, so this image is genuinely self-contained: nothing
#  to install alongside it and no network access at runtime. It is universal
#  (arm64 + x86_64) and runs on macOS 13 or later.
#
#  Built read-write first, then converted: that's the only reliable way to set
#  the volume icon, which needs the custom-icon bit applied to a live mount.
#
#  Usage:  ./make-dmg.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$SRC_DIR/VERSION")"
BUILD="$SRC_DIR/build"
STAGE="$BUILD/dmg-stage"
VOLNAME="ChampionsLab $VERSION"
RW_DMG="$BUILD/.championslab-rw.dmg"
DMG="$BUILD/ChampionsLab-$VERSION.dmg"
MOUNT="/Volumes/$VOLNAME"

cleanup() {
	# Never leave a stray mount behind on a failed run.
	if [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; fi
}
trap cleanup EXIT

echo "==> building a fresh app into the staging area"
rm -rf "$STAGE" "$RW_DMG" "$DMG"
mkdir -p "$STAGE"
"$SRC_DIR/Scripts/build.sh" "$STAGE" >/dev/null
# build.sh registers whatever it builds with LaunchServices; re-point that at
# the installed copy rather than the throwaway staging one.
if [ -d "$HOME/Applications/ChampionsLab.app" ]; then
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$HOME/Applications/ChampionsLab.app" 2>/dev/null || true
fi

echo "==> staging image contents"
ln -s /Applications "$STAGE/Applications"
cp "$SRC_DIR/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
cat > "$STAGE/First launch - please read.txt" <<'TXT'
ChampionsLab
============

A team builder and analyser for Pokemon Champions, Regulation Set M-C.

To install: drag ChampionsLab to the Applications folder in this window.


FIRST LAUNCH
------------

This app is signed ad-hoc rather than with a paid Apple Developer ID, so it
is not notarized and macOS will refuse to open it the first time, saying it
"cannot be opened because Apple cannot check it for malicious software."

That message is about the absence of an Apple-issued signature, not about
anything the app does. To allow it, once:

  1. Try to open ChampionsLab. Let the warning appear, then dismiss it.
  2. Open System Settings > Privacy & Security.
  3. Scroll to Security. Next to "ChampionsLab was blocked", click Open Anyway.
  4. Confirm, and authenticate.

From then on it opens normally. On older macOS versions you can instead
right-click the app and choose Open.

Or, from Terminal, clear the download quarantine flag directly:

  xattr -dr com.apple.quarantine /Applications/ChampionsLab.app


WHAT IT NEEDS
-------------

A universal binary (Apple silicon and Intel) using only macOS system
frameworks. Requires macOS 13 (Ventura) or later. Nothing to install alongside.

The full dataset ships inside the bundle and the app works offline. It reaches
the network in exactly one place: the Refresh button on the Usage & Meta
screen, which pulls current ladder figures from Pikalytics on request. It never
does so on its own.


WHAT IS IN IT
-------------

  - 349 forms across 231 species, including all 81 Mega Evolutions, with 902
    moves, 304 items and 214 abilities.
  - Team building for six, with ability, item, Stat Points, Stat Alignment and
    moves per slot. Species-clause, item-clause and SP-cap problems are flagged
    as you build, and teams save automatically.
  - A guided builder: pick a Mega and answer questions worked out from it, each
    option carrying the arithmetic behind it, and get complete teams back.
  - Team analysis: a defensive matrix over all 18 attacking types, offensive
    coverage, speed tiers, a per-threat verdict, and what one change would help
    most.
  - Damage calculation with weather, terrain, screens, crits, the doubles
    spread penalty, stat stages, Helping Hand, items and abilities.

Teams are scored against three kinds of opponent: written archetypes, cores
sampled from measured ladder usage, and 48 teams that people actually played at
Regulation M-C tournaments, with their records.


WHAT CHAMPIONS DOES DIFFERENTLY
-------------------------------

Stat Points replace EVs and IVs: 66 to spend, 32 maximum in one stat, each
worth +1 at Level 50. Natures are Stat Alignment, and there are 21 of them.
The app calculates on that basis throughout, and its numbers have been checked
against the values the game itself displays.

Mega Evolution is the only gimmick, one per battle, and a Mega must hold its
stone. There is no Terastallization in this game.


ON THE NUMBERS
--------------

Usage figures are real measured Regulation M-C ladder data from Pikalytics,
used under CC BY-NC 4.0. Tournament results come from the events Limitless
hosts. Compositions and placements there are real; the sets shown with them are
the ladder's most common, because team lists rarely publish spreads.

Everything the app asserts is meant to say whether it is arithmetic or
judgement. Where it is guessing, it says so.
TXT

echo "==> creating read-write image"
# Size from actual contents plus generous slack for filesystem overhead.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20480 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
	-fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_KB}k" "$RW_DMG" >/dev/null

echo "==> setting the volume icon"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT" -nobrowse -quiet
# The icon file must be present *and* the volume flagged as having a custom
# icon, or Finder ignores it. Both steps are polish; don't fail the build.
if command -v SetFile >/dev/null 2>&1; then
	SetFile -a C "$MOUNT" 2>/dev/null || echo "    (couldn't set the custom-icon bit; harmless)"
else
	echo "    (SetFile unavailable; skipping volume icon)"
fi
sync
hdiutil detach "$MOUNT" -quiet

echo "==> compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"

echo "==> verifying"
hdiutil verify "$DMG" >/dev/null && echo "    checksum ok"

echo
echo "built: $DMG"
echo "       $(du -h "$DMG" | cut -f1), universal, macOS 13+, unsigned (see the readme inside)"
