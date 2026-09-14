# ChampionsLab — the front door.
#
#   make test       the test suite (swift test): turn model, search, arithmetic
#   make hitch      main-thread stretches and search budgets, optimised build
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

.PHONY: test hitch accuracy snapshot app dmg data check clean

test:
	$(NICE) swift test 2>&1 | tail -25

hitch:
	$(NICE) ./Tools/hitch.sh

accuracy:
	$(NICE) ./Tools/accuracy.sh

snapshot:
	$(NICE) ./Tools/snapshot.sh

app:
	$(NICE) ./Scripts/build.sh

dmg:
	$(NICE) ./Scripts/make-dmg.sh

data:
	./Scripts/mkdata.py && ./Scripts/mkassets.py

check: test hitch snapshot app

clean:
	rm -rf .build build
