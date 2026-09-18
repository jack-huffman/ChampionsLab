#!/bin/bash
#  Render the main screens to build/shots/*.png for a visual once-over.
set -euo pipefail
cd "$(dirname "$0")/.."
# Built as a package target rather than a from-scratch swiftc of every
# source: that rebuilt the whole library on every run and took eleven
# minutes; the package's own incremental build takes seconds.
# Optimised: unoptimised it renders the forty-two screens in nine minutes
# and optimised in seventy seconds, because the screens do the app's own
# arithmetic -- matchup grids, bring-four searches, engine reads -- to draw
# themselves.
swift build -c release --product Snapshot
"$(swift build -c release --product Snapshot --show-bin-path)/Snapshot"
