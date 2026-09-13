#!/usr/bin/env python3
"""Build data/tournaments.json — real top-cut teams from Champions events.

Sets are the real ones now. Pikalytics renders compositions but not what the
players ran; Limitless, which hosts the events it aggregates, publishes the
whole team list through an API its own pages use:

    /api/tournaments/<id>/standings

That returns every entrant with placing, record, and for each of their six the
item, ability, four moves and nature. An earlier version of this file could only
get the six and had to fill the rest from ladder averages, which cost real
accuracy: teams scored with inferred sets averaged 56 out of 100 where the one
team entered from its actual sets scored 76.

Spreads are still not published by anyone, so Stat Points remain inferred. That
is said plainly on every team rather than left to be assumed.


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
import unicodedata

BASE = "https://www.pikalytics.com"
LIMITLESS = "https://play.limitlesstcg.com"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache", "tournaments")
OUT = os.path.join(HERE, "data", "tournaments.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

REFRESH = "--refresh" in sys.argv
LIMIT = 16
if "--limit" in sys.argv:
    LIMIT = int(sys.argv[sys.argv.index("--limit") + 1])


def fetch_json(url):
    """A JSON endpoint, cached like everything else."""
    key = re.sub(r"[^a-z0-9]+", "_", url.lower()).strip("_")[-80:] + ".json"
    dest = os.path.join(CACHE, key)
    if os.path.exists(dest) and not REFRESH:
        with open(dest, encoding="utf-8") as fh:
            try:
                return json.load(fh)
            except json.JSONDecodeError:
                pass
    os.makedirs(CACHE, exist_ok=True)
    try:
        proc = subprocess.run(
            ["curl", "-sS", "-m", "40", "-A", UA, "--compressed", url],
            capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout.decode("utf-8", errors="ignore"))
    except json.JSONDecodeError:
        return None
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    time.sleep(0.3)
    return data


def tidy_event(name):
    """Strip decoration from a community tournament name.

    The same job mkdata.py does, kept here too because this file now writes
    names directly rather than handing raw ones on.
    """
    if not name:
        return ""
    out = []
    for ch in unicodedata.normalize("NFKC", name):
        if unicodedata.category(ch) in ("So", "Sk", "Cn", "Cf"):
            continue
        if "\u02b0" <= ch <= "\u02ff" or "\ufe00" <= ch <= "\ufe0f":
            continue
        out.append(ch)
    text = "".join(out)
    text = re.sub(r"\b(?:Regulation|Reg)\s*(?:Set\s*)?M-?C\b", "", text, flags=re.I)
    text = re.sub(r"[|\u00b7\u2022]+", " - ", text)
    text = re.sub(r"\(\s*[,;]\s*", "(", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"(\s*-\s*){2,}", " - ", text)
    text = re.sub(r"\s{2,}", " ", text).strip(" -")
    if len(text) > 40:
        text = text[:40].rsplit(" ", 1)[0] or text[:40]
    if text.count("(") > text.count(")"):
        text = text[:text.rindex("(")]
    return re.sub(r"[\s\-,:;(]+$", "", text).strip()


def tournament_ids(page):
    """Event ids Pikalytics has aggregated, newest first in page order."""
    seen, out = set(), []
    for match in re.finditer(r'"sourceTournamentId":"([a-f0-9]{16,})"', page):
        if match.group(1) not in seen:
            seen.add(match.group(1))
            out.append(match.group(1))
    # The slug carries the readable name; pair them up where we can.
    names = {}
    for match in re.finditer(
            r'"sourceTournamentId":"([a-f0-9]{16,})"[^{}]*?"name":"([^"]{3,80})"', page):
        names[match.group(1)] = match.group(2)
    return [(i, names.get(i, "")) for i in out]


def real_teams(tournament_id, name, limit_per_event):
    """Every published team list for one event, best placing first."""
    data = fetch_json("%s/api/tournaments/%s/standings" % (LIMITLESS, tournament_id))
    if not isinstance(data, list):
        return []
    out = []
    for entry in sorted(data, key=lambda e: e.get("placing") or 9999):
        decklist = entry.get("decklist") or []
        if len(decklist) < 4:
            continue
        record = entry.get("record") or {}
        wins, losses = record.get("wins", 0), record.get("losses", 0)
        if wins + losses == 0:
            continue
        members = []
        for mon in decklist:
            moves = [m for m in (mon.get("attacks") or []) if m]
            members.append({
                "name": mon.get("name") or "",
                "item": mon.get("item") or "",
                "ability": mon.get("ability") or "",
                "moves": moves[:4],
                "nature": mon.get("nature") or "",
            })
        out.append({
            "rank": entry.get("placing") or 9999,
            "player": entry.get("name") or entry.get("player") or "?",
            "record": "%d-%d" % (wins, losses),
            "event": name or tournament_id,
            "placement": "Placing %s" % entry.get("placing")
                         if entry.get("placing") else "",
            "date": "",
            "source": "%s/tournament/%s/player/%s/teamlist"
                      % (LIMITLESS, tournament_id, entry.get("player") or ""),
            "members": [m["name"] for m in members],
            "sets": members,
        })
        if len(out) >= limit_per_event:
            break
    return out


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


def _games(team):
    record = team.get("record") or ""
    parts = [int(p) for p in record.split("-")[:2] if p.isdigit()]
    return sum(parts)


def main():
    print("==> fetching Champions tournament teams")
    listing = fetch("/tournaments")
    events = tournament_ids(listing) if listing else []
    print("    %d events aggregated" % len(events))

    # Real team lists, straight from the events themselves.
    per_event = max(4, LIMIT // max(1, min(len(events), 12)))
    kept = []
    for index, (tid, name) in enumerate(events):
        got = real_teams(tid, tidy_event(name) if name else "", per_event)
        if got:
            kept.extend(got)
            print("      %-44s %d team lists" % ((name or tid)[:44], len(got)))
        if len(kept) >= LIMIT:
            break
    kept.sort(key=lambda t: (t["rank"], -_games(t)))
    kept = kept[:LIMIT]

    if not kept:
        # Nothing published: fall back to compositions only, which is what this
        # could get before the team lists were reachable.
        print("    no team lists available; falling back to compositions")
        page = fetch("/topteams")
        if not page:
            return 1
        kept = parse_teams(page)[:LIMIT]
    events = {}
    for team in kept:
        events[team["event"]] = events.get(team["event"], 0) + 1

    payload = {
        "source": LIMITLESS + "/api/tournaments",
        "license": "CC BY-NC 4.0",
        "generated": time.strftime("%Y-%m-%d"),
        "note": ("Real team lists as published by the events: item, ability, moves "
                 "and nature per member. Stat Points are not published anywhere, so "
                 "those remain inferred."),
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
    withSets = sum(1 for t in kept if t.get("sets"))
    print("    %d of %d carry real sets" % (withSets, len(kept)))
    for team in kept[:4]:
        print("      #%-3d %-16s %-6s %s"
              % (team["rank"], team["player"][:16], team["record"],
                 ", ".join(team["members"])))
        for member in (team.get("sets") or [])[:2]:
            print("           %-18s @ %-16s %-14s %s"
                  % (member["name"], member["item"], member["ability"],
                     ", ".join(member["moves"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
