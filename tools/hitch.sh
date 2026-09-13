#!/bin/bash
#  Measure the longest stretch the main thread runs without a break.
#
#  Compiles every app source except ChampionsLab.swift, whose @main would
#  collide with this tool's own.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=$(ls ./*.swift | grep -v 'ChampionsLab.swift')
mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/hitch $SOURCES tools/hitch/main.swift
./build/hitch
