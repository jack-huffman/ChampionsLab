#!/bin/bash
#  Play real games at scale and write down what happened in them.
#
#  Built with -O, unlike the other tools. The lab's whole cost is the engine
#  thinking, and an unoptimised build thinks several times slower — which for
#  one duel is a wait and for a thousand games is the difference between a
#  minute and an afternoon.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
mkdir -p build
# Only rebuild when something actually changed. The -O compile is around a
# hundred seconds and the games themselves are seconds, so rebuilding every
# run made the tool feel far slower than it is.
NEWEST=$(find Sources/ChampionsLab Tools/lab -name '*.swift' -newer build/lab 2>/dev/null | head -1 || true)
if [ ! -x build/lab ] || [ -n "$NEWEST" ]; then
	echo "==> building the lab (optimised; this is the slow part)" >&2
	swiftc -swift-version 6 -O -target arm64-apple-macosx13.0 -sdk "$SDK" \
		-o build/lab $SOURCES Tools/lab/main.swift
fi
./build/lab "$@"
