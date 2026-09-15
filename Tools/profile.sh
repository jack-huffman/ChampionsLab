#!/bin/bash
#  Time the pieces a search is made of.
#
#  Compiles every app source except ChampionsLab.swift, whose @main would
#  collide with this tool's own.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
mkdir -p build
swiftc -O -swift-version 6 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/profile $SOURCES Tools/profile/main.swift
./build/profile
