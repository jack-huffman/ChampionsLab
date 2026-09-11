#!/bin/bash
#  Run the stat/damage verification harness against data/champions.json.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
	-o build/verify \
	Model.swift Types.swift Stats.swift Damage.swift MoveQuality.swift tools/main.swift
./build/verify
