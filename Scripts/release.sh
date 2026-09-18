#!/bin/bash
#  Cut a release: the version, the disk image, the tag, the push, and the
#  GitHub release the app updates itself from.
#
#  Usage:  ./Scripts/release.sh            release the version in VERSION
#          ./Scripts/release.sh 0.4.1      set VERSION first, committing it
#
#  Needs a clean tree and the GitHub CLI signed in as the repository's owner.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC_DIR"

if [ -n "$(git status --porcelain)" ]; then
	echo "error: the working tree is not clean; commit first." >&2
	exit 1
fi
if [ -n "${1:-}" ]; then
	echo "$1" > VERSION
	git add VERSION
	git commit -q -m "Version $1"
fi
VERSION="$(cat VERSION)"
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	echo "error: $TAG already exists." >&2
	exit 1
fi

echo "==> building ChampionsLab $VERSION"
nice -n 15 ./Scripts/make-dmg.sh
DMG="build/ChampionsLab-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: $DMG was not built." >&2; exit 1; }

# The notes are the commits since the last release, one line each.
PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREVIOUS" ]; then
	NOTES="$(git log --format='- %s' "$PREVIOUS..HEAD")"
else
	NOTES="$(git log --format='- %s' -n 30)"
fi

echo "==> tagging and pushing"
git tag -a "$TAG" -m "ChampionsLab $VERSION"
git push origin HEAD
git push origin "$TAG"

echo "==> publishing the release"
gh release create "$TAG" "$DMG" --title "ChampionsLab $VERSION" --notes "$NOTES"
echo "released: $TAG with $DMG"
