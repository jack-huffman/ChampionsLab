#!/bin/bash
#  Score the engine against real games with known team lists on both sides.
#
#  Needs data/matches.json, which ./mkmatches.py builds.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(find Sources/ChampionsLab -name '*.swift')
mkdir -p build
swiftc -O -swift-version 6 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/accuracy $SOURCES Tools/accuracy/main.swift
./build/accuracy
