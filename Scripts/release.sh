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
# This machine's HTTPS drops large uploads over HTTP/2 ("bad record MAC"),
# for git pushes and for the GitHub CLI alike, so the CLI is held to HTTP/1.1
# and the upload is tried more than once. The release is made first, empty,
# so a failed upload leaves something to retry against.
export GODEBUG=http2client=0
gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --title "ChampionsLab $VERSION" --notes "$NOTES"
for attempt in 1 2 3 4; do
	if gh release upload "$TAG" "$DMG" --clobber; then
		echo "released: $TAG with $DMG"
		exit 0
	fi
	echo "upload attempt $attempt failed; trying again" >&2
	sleep 5
done
echo "error: the image could not be uploaded; the release $TAG exists without it. Try: gh release upload $TAG $DMG --clobber" >&2
exit 1
