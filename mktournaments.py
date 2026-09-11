#!/usr/bin/env python3
"""Build data/tournaments.json — real top-cut teams from Champions events.

The app scored teams against seven archetypes written by hand plus cores
sampled from usage. Neither is a team a person actually took to an event and
won with. Pikalytics aggregates the tournament results that Limitless hosts,
and its top-teams page carries the composition, the player, the record, the
event and the placement for each one.

What this can and cannot get: compositions, yes, with full provenance. Complete
sets — items, moves, spreads — are not in that markup, so each member is given
the set the ladder actually runs for it, from data/usage.json. Every team here
therefore says where its composition came from and that its sets are inferred.

    ./mktournaments.py                # recent Champions events
    ./mktournaments.py --refresh      # ignore the cache
    ./mktournaments.py --limit 16     # how many teams to keep
"""

import html
import json
import os
import re
import subprocess
import sys
import time

BASE = "https://www.pikalytics.com"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache", "tournaments")
OUT = os.path.join(HERE, "data", "tournaments.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

REFRESH = "--refresh" in sys.argv
LIMIT = 16
if "--limit" in sys.argv:
    LIMIT = int(sys.argv[sys.argv.index("--limit") + 1])


def fetch(path):
    key = re.sub(r"[^a-z0-9]+", "_", path.lower()).strip("_") + ".html"
    dest = os.path.join(CACHE, key)
    if os.path.exists(dest) and not REFRESH:
        with open(dest, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    os.makedirs(CACHE, exist_ok=True)
    proc = subprocess.run(
        ["curl", "-sS", "-m", "40", "-A", UA, "--compressed", BASE + path],
        capture_output=True, timeout=60)
    if proc.returncode != 0:
        return ""
    body = proc.stdout.decode("utf-8", errors="ignore")
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(body)
    return body


def text_after(block, css_class):
    """The text inside the first element carrying this class."""
    match = re.search(r'class="[^"]*%s[^"]*"[^>]*>([^<]*)<' % re.escape(css_class), block)
    return html.unescape(match.group(1)).strip() if match else ""


def parse_teams(page):
    """Split the top-teams page into one record per entry."""
    starts = [m.start() for m in re.finditer(r'<div class="aggregated-team-entry', page)]
    out = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(page)
        block = page[start:end]

        author = re.search(r'data-author-id="([^"]*)"', block)
        members = re.findall(r'class="topteams-pokemon-collage-image"[^>]*alt="([^"]+)"', block)
        if len(members) < 4:
            continue
        stamp = re.search(r'topteams-team-age"\s+title="([^"]+)"', block)
        source = re.search(r'href="(https://play\.limitlesstcg\.com/[^"]+)"', block)

        out.append({
            "rank": int(text_after(block, "topteams-team-rank").lstrip("#") or index + 1),
            "player": text_after(block, "team-author-info") or (author.group(1) if author else "?"),
            "record": text_after(block, "topteams-record-badge"),
            "event": text_after(block, "topteams-event-name"),
            "placement": text_after(block, "topteams-event-placement"),
            "date": (stamp.group(1)[:10] if stamp else ""),
            "source": source.group(1) if source else "",
            "members": members[:6],
        })
    return out


def main():
    print("==> fetching Champions tournament teams")
    page = fetch("/topteams")
    if not page:
        print("could not fetch the top-teams page")
        return 1
    teams = parse_teams(page)
    print("    %d team entries on the page" % len(teams))
    if not teams:
        return 1

    kept = teams[:LIMIT]
    events = {}
    for team in kept:
        events[team["event"]] = events.get(team["event"], 0) + 1

    payload = {
        "source": BASE + "/topteams",
        "license": "CC BY-NC 4.0",
        "generated": time.strftime("%Y-%m-%d"),
        "note": ("Compositions and placements are real tournament results. Sets are "
                 "not published in that markup, so each member is given the ladder's "
                 "most common item, ability and moves."),
        "teams": kept,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, ensure_ascii=False)

    print("==> wrote %s (%d teams)" % (OUT, len(kept)))
    print("    events represented:")
    for name, count in sorted(events.items(), key=lambda kv: -kv[1]):
        print("      %2dx %s" % (count, name))
    print("    newest %s, oldest %s"
          % (max(t["date"] for t in kept), min(t["date"] for t in kept)))
    for team in kept[:5]:
        print("      #%-3d %-16s %-6s %s"
              % (team["rank"], team["player"][:16], team["record"],
                 ", ".join(team["members"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
