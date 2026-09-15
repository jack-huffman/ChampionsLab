#!/usr/bin/env python3
"""Pull real Champions games — exact teams, exact choices, turn by turn.

    ./mkreplays.py                 catch up: newest first, stop at what we have
    ./mkreplays.py --pages 40      go deeper into the archive
    ./mkreplays.py --format <id>   a different format

Why this exists.

Everything the engine was measured against until now was a *team list and a
result*: who brought what, and who won. `make accuracy` reads 1,455 of those
and cannot see a turn, which is why it reported the same number no matter what
the battle model did.

Pokemon Showdown runs the same format this app is built for — "[Gen 9
Champions] VGC 2026 Reg M-C" — and publishes every ladder game as a replay:
both full teams from team preview, which four each side brought, and then every
turn with each side's exact choice in resolution order. Thousands of them.

That is the missing half. Two things it makes possible that nothing here could
do before:

  * Replay a real game through our own turn model and check the damage we work
    out against the damage that actually happened. A behavioural audit proves a
    move does *something*; this proves it does the right amount, which is the
    blind spot that hid Double Hit doing half its damage.

  * Ask how often our engine would have chosen what the player chose. That is a
    far sharper read on playing strength than predicting a winner from two team
    lists.

What it cannot give.

Stat Points are not in a replay, the same way they are not on a registered team
list, so spreads still have to be inferred. Damage arrives as a percentage of
the bar rather than a number, which is enough to check a calculation to within
a point. And these are ladder games: ratings run from about 1000 to 1500, and
plenty end in a forfeit after three turns. The parser keeps the rating and the
turn count so a caller can ask for the good ones.

Cached under .cache/replays/, one file per game, so a re-run costs nothing and
an interrupted one resumes. Fetches are spaced out: this is somebody's server
and it is free.
"""

import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(HERE, ".cache", "replays")
OUT = os.path.join(HERE, "data", "replays.json")
BASE = "https://replay.pokemonshowdown.com"
UA = "ChampionsLab/0.3 (offline analysis; contact via repository)"

FORMAT = "gen9championsvgc2026regmc"
PAGES = 8
DELAY = 0.4


def argument(flag, fallback):
    if flag in sys.argv:
        at = sys.argv.index(flag)
        if at + 1 < len(sys.argv):
            return sys.argv[at + 1]
    return fallback


def get(url):
    """One request, with the courtesies.

    The system curl rather than urllib, for the same reason mkdata.py uses it:
    this machine's Python does not trust a chain the system keychain does, and
    urllib raises CERTIFICATE_VERIFY_FAILED where curl simply works.
    """
    try:
        proc = subprocess.run(["curl", "-sS", "-m", "30", "-A", UA, "--compressed", url],
                              capture_output=True, timeout=45)
    except subprocess.TimeoutExpired:
        print("  ! %s: timed out" % url.rsplit("/", 1)[-1])
        return None
    if proc.returncode != 0 or not proc.stdout:
        print("  ! %s: %s" % (url.rsplit("/", 1)[-1],
                              proc.stderr.decode("utf-8", "ignore").strip()[:80]))
        return None
    try:
        return json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        return None


def listing(fmt, pages):
    """Replay ids, newest first."""
    found = []
    for page in range(1, pages + 1):
        rows = get("%s/search.json?format=%s&page=%d" % (BASE, fmt, page))
        if not rows:
            break
        found += [row["id"] for row in rows if "id" in row]
        print("    page %d: %d" % (page, len(rows)))
        time.sleep(DELAY)
    # The API repeats an entry across page boundaries; keep the order, drop dupes.
    seen, ordered = set(), []
    for one in found:
        if one not in seen:
            seen.add(one)
            ordered.append(one)
    return ordered


def fetch(replay_id):
    """One replay, cached."""
    os.makedirs(CACHE, exist_ok=True)
    dest = os.path.join(CACHE, replay_id + ".json")
    if os.path.exists(dest):
        with open(dest, encoding="utf-8") as fh:
            try:
                return json.load(fh)
            except ValueError:
                pass
    body = get("%s/%s.json" % (BASE, replay_id))
    if body is None:
        return None
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump(body, fh)
    time.sleep(DELAY)
    return body


# ------------------------------------------------------------------ parse ----

def nickname(slot_and_name):
    """"p1a: Gardevoir" -> ("p1a", "Gardevoir")."""
    if ": " in slot_and_name:
        slot, name = slot_and_name.split(": ", 1)
        return slot, name
    return slot_and_name, slot_and_name


def species(details):
    """"Gardevoir-Mega, L50, F, shiny" -> "Gardevoir-Mega"."""
    return details.split(",")[0].strip()


def parse(body):
    """A replay's protocol log, as teams and per-turn choices.

    The log is Showdown's battle protocol: one message per line, pipe
    separated. Only a handful of message types matter here.

      |poke|p1|Golisopod, L50, M|     team preview, all six
      |switch|p1a: X|X, L50, M|100/100  who is standing where
      |move|p1a: X|Heat Wave|p2a: Y   a choice, in resolution order
      |-damage|p2a: Y|61/100          what it cost, as a share of the bar
      |turn|3                         everything above belongs to turn 2
      |win|Someone                    the end

    Choices are recorded per turn per side. A switch a player *chose* and a
    switch forced by a faint look identical in the log except for position:
    a chosen one happens before any move of that turn, a forced one after
    something has fainted. That is tracked, because a forced switch is not a
    decision and would poison an agreement rate.
    """
    log = body.get("log") or ""
    if not log:
        return None

    teams = {"p1": [], "p2": []}
    brought = {"p1": [], "p2": []}
    who = {}                       # slot -> species currently standing there
    turns = []
    current = {"n": 0, "p1": [], "p2": []}
    winner = None
    fainted_this_turn = False
    started = False

    for line in log.split("\n"):
        if not line.startswith("|"):
            continue
        parts = line.split("|")[1:]
        if not parts:
            continue
        tag = parts[0]

        if tag == "poke" and len(parts) >= 3:
            side = parts[1]
            if side in teams:
                teams[side].append(species(parts[2]))
        elif tag == "start":
            started = True
        elif tag == "switch" and len(parts) >= 3:
            slot, _ = nickname(parts[1])
            side = slot[:2]
            name = species(parts[2])
            who[slot] = name
            # A Pokemon that has Mega Evolved and then switched back in comes
            # through as "Froslass-Mega", which is the same Pokemon and would
            # otherwise read as a fifth one brought.
            base = name
            if side in teams and name not in teams[side]:
                stem = re.sub(r"-(Mega|Mega-[XYZ])$", "", name)
                if stem in teams[side]:
                    base = stem
            if side in brought and base not in brought[side]:
                brought[side].append(base)
            # A switch before the first turn is the opening, not a choice.
            if started and current["n"] >= 1 and side in current:
                current[side].append({
                    "slot": slot, "action": "switch", "to": name,
                    "forced": fainted_this_turn,
                })
        elif tag == "move" and len(parts) >= 3:
            slot, _ = nickname(parts[1])
            side = slot[:2]
            target = nickname(parts[3])[0] if len(parts) > 3 and parts[3] else ""
            if side in current:
                current[side].append({
                    "slot": slot, "action": "move", "move": parts[2],
                    "target": target, "by": who.get(slot, ""),
                })
        elif tag == "-damage" and len(parts) >= 3:
            slot, _ = nickname(parts[1])
            share = parts[2].split(" ")[0]
            left = 0.0
            if share.startswith("0"):
                left = 0.0
            else:
                bar = re.match(r"(\d+)\\?/(\d+)", share)
                if bar:
                    left = int(bar.group(1)) / max(1, int(bar.group(2))) * 100
            side = slot[:2]
            if side in current:
                current[side].append({"slot": slot, "action": "damaged",
                                      "left": round(left, 1)})
        elif tag == "faint":
            fainted_this_turn = True
        elif tag == "turn" and len(parts) >= 2:
            if current["n"] >= 1:
                turns.append(current)
            current = {"n": int(parts[1]), "p1": [], "p2": []}
            fainted_this_turn = False
        elif tag == "win" and len(parts) >= 2:
            winner = parts[1]

    if current["n"] >= 1:
        turns.append(current)

    players = body.get("players") or []
    return {
        "id": body.get("id"),
        "format": body.get("formatid"),
        "uploaded": body.get("uploadtime"),
        "rating": body.get("rating"),
        "players": players,
        "teams": teams,
        "brought": brought,
        "turns": turns,
        "winner": ("p1" if players and winner == players[0]
                   else "p2" if len(players) > 1 and winner == players[1] else None),
    }


def main():
    fmt = argument("--format", FORMAT)
    pages = int(argument("--pages", PAGES))
    print("==> listing %s, %d pages" % (fmt, pages))
    ids = listing(fmt, pages)
    print("    %d replays" % len(ids))

    games, skipped = [], 0
    for index, replay_id in enumerate(ids, 1):
        body = fetch(replay_id)
        if body is None:
            skipped += 1
            continue
        game = parse(body)
        if game is None or not game["turns"]:
            skipped += 1
            continue
        games.append(game)
        if index % 25 == 0:
            print("    %d/%d" % (index, len(ids)))

    played = [g for g in games if len(g["turns"]) >= 4]
    rated = [g for g in games if (g["rating"] or 0) >= 1300]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump({
            "source": "https://replay.pokemonshowdown.com",
            "note": ("Ladder games in the same format this app is built for. Teams and "
                     "per-turn choices are exact; Stat Points are not published, and "
                     "damage is a share of the bar rather than a number."),
            "format": fmt,
            "generated": time.strftime("%Y-%m-%d"),
            "games": games,
        }, fh, separators=(",", ":"))
    print("==> wrote %s (%.1f MB)" % (OUT, os.path.getsize(OUT) / 1e6))
    print("    %d games, %d of four turns or more, %d rated 1300+, %d skipped"
          % (len(games), len(played), len(rated), skipped))
    if games:
        turns = sorted(len(g["turns"]) for g in games)
        print("    turns per game: shortest %d, middle %d, longest %d"
              % (turns[0], turns[len(turns) // 2], turns[-1]))


if __name__ == "__main__":
    main()
