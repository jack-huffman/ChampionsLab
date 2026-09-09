#!/bin/bash
#  Render the main screens to build/shots/*.png for a visual once-over.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
# Every app source except ChampionsLab.swift, which owns @main.
SOURCES=$(ls ./*.swift | grep -v 'ChampionsLab.swift')
swiftc -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/snapshot $SOURCES tools/snapshot/main.swift
./build/snapshot
