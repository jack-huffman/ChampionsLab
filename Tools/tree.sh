#!/bin/bash
#  One matchup, every decision you could make in it.
#
#  Built with -O: the cost is the solver running once per internal node, and a
#  debug build makes that about four times slower than it needs to be.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
mkdir -p build
NEWEST=$(find Sources/ChampionsLab Tools/tree -name '*.swift' -newer build/tree 2>/dev/null | head -1 || true)
if [ ! -x build/tree ] || [ -n "$NEWEST" ]; then
	echo "==> building the tree (optimised; this is the slow part)" >&2
	swiftc -swift-version 6 -O -target arm64-apple-macosx13.0 -sdk "$SDK" \
		-o build/tree $SOURCES Tools/tree/main.swift
fi
./build/tree "$@"
