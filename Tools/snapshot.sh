#!/bin/bash
#  Render the main screens to build/shots/*.png for a visual once-over.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
# Every app source except ChampionsLab.swift, which owns @main.
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
swiftc -swift-version 6 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/snapshot $SOURCES Tools/snapshot/main.swift
./build/snapshot
