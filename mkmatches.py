#!/usr/bin/env python3
"""Build data/matches.json — real games, with both team lists and who won.

Everything else in this project is measured against itself. The team score, the
versus grid, the bring-four search: all of them were built by reasoning about
mechanics and checked by reading the output, which is how every bug found so far
was found. Not one was caught by comparing a prediction to a result, because
there were no results to compare against.

Limitless publishes them. The standings endpoint gives every entrant's full team
list, and the pairings endpoint gives every round's result. Join the two and you
have games where both sixes are known and the winner is known — several thousand
of them across the Regulation M-C events.

That is ground truth for the matchup engine, and it answers the question the
whole app rests on: when it says one side is ahead by twenty, does that side
actually win more often?

Kept separate from data/champions.json on purpose. The app bundles a curated
hundred teams to score against; this is a much larger pile that only the
accuracy harness reads, and there is no reason to ship it inside the binary.

    ./mkmatches.py                # every M-C event
    ./mkmatches.py --events 6     # a quicker pass
"""

import json
import os
import re
import sys
import time

import mkdata
import mktournaments as src

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "matches.json")

LIMIT_EVENTS = None
if "--events" in sys.argv:
    LIMIT_EVENTS = int(sys.argv[sys.argv.index("--events") + 1])


def dex_labels():
    """Every name the app knows a Pokemon by."""
    with open(os.path.join(HERE, "data", "champions.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    out = set()
    for form in data["forms"]:
        out.add(form["form_label"])
        out.add(form["name"])
    return out


KNOWN = dex_labels()


def resolved(raw):
    """A team list's name, as the app spells it.

    Limitless writes what the game shows -- "Eternal Flower Floette", "Wash
    Rotom", "Indeedee (female symbol)" -- and the dex is built from Serebii,
    which spells all three differently. The same table the bundled teams are
    built through is used here, so a match and a meta team agree about what a
    Pokemon is called.
    """
    if raw in KNOWN:
        return raw
    mapped = mkdata.TOURNAMENT_ALIASES.get(raw)
    if mapped and mapped in KNOWN:
        return mapped
    # "Low Key Toxtricity" and friends: the form in front of the species.
    words = raw.split()
    for cut in range(1, len(words)):
        candidate = "%s (%s)" % (" ".join(words[cut:]), " ".join(words[:cut]))
        if candidate in KNOWN:
            return candidate
    # Some forms are cosmetic or share a stat line, and the dex carries only the
    # species -- Toxtricity's two forms and Meowstic's two sexes both do. Strip
    # the qualifier rather than dropping the Pokemon.
    trimmed = raw.replace("\u2640", "").replace("\u2642", "").strip()
    if trimmed in KNOWN:
        return trimmed
    for cut in range(1, len(words)):
        tail = " ".join(words[cut:])
        if tail in KNOWN:
            return tail
    return raw


def lists_for(tournament_id):
    """Every entrant with a published team, keyed by the name pairings use."""
    data = src.fetch_json("%s/api/tournaments/%s/standings" % (src.LIMITLESS, tournament_id))
    if not isinstance(data, list):
        return {}
    out = {}
    for entry in data:
        decklist = entry.get("decklist") or []
        if len(decklist) < 4:
            continue
        members = []
        for mon in decklist:
            members.append({
                "name": resolved(mon.get("name") or ""),
                "item": mon.get("item") or "",
                "ability": mon.get("ability") or "",
                "moves": [m for m in (mon.get("attacks") or []) if m][:4],
                "nature": mon.get("nature") or "",
            })
        record = entry.get("record") or {}
        # Pairings name players by their handle; standings carry both.
        for key in (entry.get("player"), entry.get("name")):
            if key:
                out[str(key).strip().lower()] = {
                    "player": entry.get("name") or entry.get("player"),
                    "placing": entry.get("placing"),
                    "record": "%d-%d" % (record.get("wins", 0), record.get("losses", 0)),
                    "members": members,
                }
    return out


def games_for(tournament_id, teams):
    """Decided matches where both sides published a list."""
    data = src.fetch_json("%s/api/tournaments/%s/pairings" % (src.LIMITLESS, tournament_id))
    if not isinstance(data, list):
        return []
    out = []
    for match in data:
        one = str(match.get("player1") or "").strip().lower()
        two = str(match.get("player2") or "").strip().lower()
        winner = str(match.get("winner") or "").strip().lower()
        # -1 is an undecided or unplayed table; a tie has no winner to learn from.
        if not one or not two or winner in ("", "-1", "none"):
            continue
        if winner not in (one, two):
            continue
        if one not in teams or two not in teams:
            continue
        out.append({
            "round": match.get("round"),
            "a": teams[one],
            "b": teams[two],
            # 0 when the first side won, 1 when the second did.
            "winner": 0 if winner == one else 1,
        })
    return out


def main():
    print("==> fetching Champions events")
    listing = src.fetch("/tournaments")
    events = src.tournament_ids(listing) if listing else []
    # Community series run several regulations at once; only this one counts.
    events = [(tid, name) for tid, name in events
              if not re.search(r"\bM-?B\b", name or "", re.I)]
    if LIMIT_EVENTS:
        events = events[:LIMIT_EVENTS]
    print("    %d events in this regulation" % len(events))

    matches, seen = [], set()
    for tid, name in events:
        teams = lists_for(tid)
        if not teams:
            continue
        games = games_for(tid, teams)
        label = src.tidy_event(name) if name else tid
        for game in games:
            # The same pairing can appear twice in a phase listing.
            key = (label, game["round"], game["a"]["player"], game["b"]["player"])
            if key in seen:
                continue
            seen.add(key)
            game["event"] = label
            matches.append(game)
        print("      %-46s %3d lists, %3d games" % (label[:46], len(teams) // 2, len(games)))

    payload = {
        "source": src.LIMITLESS + "/api/tournaments",
        "license": "CC BY-NC 4.0",
        "generated": time.strftime("%Y-%m-%d"),
        "note": ("Decided games from published brackets, with both team lists. "
                 "Stat Points are not published, so the spreads either side "
                 "fought with are inferred and this measures everything else."),
        "matches": matches,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)

    print("==> wrote %s" % OUT)
    print("    %d games, %d distinct events" % (len(matches),
                                                len({m["event"] for m in matches})))
    players = {m["a"]["player"] for m in matches} | {m["b"]["player"] for m in matches}
    print("    %d distinct players" % len(players))
    unknown = set()
    for match in matches:
        for side in ("a", "b"):
            for member in match[side]["members"]:
                if member["name"] not in KNOWN:
                    unknown.add(member["name"])
    if unknown:
        print("    names the dex does not know: %s" % ", ".join(sorted(unknown)[:8]))
    else:
        print("    every named Pokemon resolves against the dex")
    firsts = sum(1 for m in matches if m["winner"] == 0)
    print("    first-named side won %d of %d (%.1f%%), which should be about half"
          % (firsts, len(matches), 100.0 * firsts / max(1, len(matches))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
