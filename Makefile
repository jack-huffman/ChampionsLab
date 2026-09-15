# ChampionsLab — the front door.
#
#   make test       the test suite (swift test): turn model, search, arithmetic
#   make hitch      main-thread stretches and search budgets, optimised build
#   make coverage   what the battle model implements, and what it does not
#   make profile    where a search spends its time
#   make accuracy   the engine against real games (slow; needs data/matches.json)
#   make snapshot   render every screen to build/shots/*.png
#   make app        build ChampionsLab.app into ~/Applications
#   make dmg        a signed disk image
#   make data       regenerate data/champions.json and the sprite set
#   make check      everything a change should pass before it is committed
#
# Tools run one at a time, at low priority: several concurrent compiles made
# the machine stutter, and the timing check only means something on a quiet
# CPU.

SHELL := /bin/bash
NICE  := nice -n 15

.PHONY: test warnings hitch coverage profile accuracy snapshot app dmg data check clean delta full-sync

test:
	$(NICE) swift test 2>&1 | tail -25

# The build must stay warning-free in Swift 6 language mode: everything below
# the interface runs off the main thread, and that is only safe because the
# compiler can see it is.
warnings:
	@rm -rf .build
	@$(NICE) swift build 2>&1 | grep -E "warning:|error:" || echo "no warnings"

hitch:
	$(NICE) ./Tools/hitch.sh

accuracy:
	$(NICE) ./Tools/accuracy.sh

# What the battle model implements, and what it does not. Moves are audited by
# using them; abilities and items by reading the model. Ranked by usage, so
# the gaps that matter come first.
coverage:
	$(NICE) ./Tools/coverage.sh

# Where a search spends its time. Optimise what this says is slow.
profile:
	$(NICE) ./Tools/profile.sh

snapshot:
	$(NICE) ./Tools/snapshot.sh

app:
	$(NICE) ./Scripts/build.sh

dmg:
	$(NICE) ./Scripts/make-dmg.sh

# Rebuild from the page cache. Cannot see a new release: every page it needs
# is already on disk.
data:
	./Scripts/mkdata.py && ./Scripts/mkassets.py

# Pick up a new Champions release. Re-reads the three index pages, then fetches
# detail pages only for what they name that is not already in the dataset.
# This is the one to reach for when a release lands.
delta:
	./Scripts/mkdata.py --delta && ./Scripts/mkassets.py

# Re-fetch all fourteen hundred pages. Slow, and only needed when Serebii has
# changed a page the indexes do not flag -- a correction rather than an
# addition.
full-sync:
	./Scripts/mkdata.py --full && ./Scripts/mkassets.py

check: test warnings hitch snapshot app

clean:
	rm -rf .build build
