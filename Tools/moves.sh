#!/bin/bash
#  Compare the engine's turn-one choices against what people actually played.
#
#  Built with -O: the whole cost here is the engine thinking, once per position,
#  across a couple of thousand positions.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
mkdir -p build
# Only rebuild when something actually changed. The -O compile is around a
# hundred seconds and the games themselves are seconds, so rebuilding every
# run made the tool feel far slower than it is.
NEWEST=$(find Sources/ChampionsLab Tools/moves -name '*.swift' -newer build/moves 2>/dev/null | head -1 || true)
if [ ! -x build/moves ] || [ -n "$NEWEST" ]; then
	echo "==> building the moves (optimised; this is the slow part)" >&2
	swiftc -swift-version 6 -O -target arm64-apple-macosx13.0 -sdk "$SDK" \
		-o build/moves $SOURCES Tools/moves/main.swift
fi
./build/moves "$@"
