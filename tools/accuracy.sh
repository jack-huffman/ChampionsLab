#!/bin/bash
#  Score the engine against real games with known team lists on both sides.
#
#  Needs data/matches.json, which ./mkmatches.py builds.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(ls ./*.swift | grep -v 'ChampionsLab.swift')
mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/accuracy $SOURCES tools/accuracy/main.swift
./build/accuracy
