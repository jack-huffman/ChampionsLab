#!/bin/bash
#  Fit the scoring weights against real tournament records.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
mkdir -p build
swiftc -O -swift-version 5 -parse-as-library \
	-target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/calibrate \
	$(find Sources/ChampionsLab -name '*.swift') Tools/calibrate/main.swift
./build/calibrate
