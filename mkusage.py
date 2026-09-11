#!/usr/bin/env python3
"""Build data/usage.json — real per-Pokemon usage from Pikalytics.

Everything else in this project is scraped from Serebii, which publishes what a
Pokemon *can* do but nothing about what people actually run. That gap was filled
by a hand-written table of about thirty entries, which was guesswork: it listed
Pokemon that are not in the game, and gave one of them a move no Champions
Pokemon learns.

Pikalytics publishes the real thing, and usefully embeds it as JSON-LD FAQ
answers on each Pokemon's page, so the numbers can be read without scraping a
rendered table:

    "The top moves for Garchomp ... are Dragon Claw (89.4%), Rock Slide (82.0%),
     Earthquake (80.7%), Protect (70.2%)."

Their data is CC BY-NC 4.0, so the app credits them on screen.

    ./mkusage.py                      # current Regulation M-C ladder
    ./mkusage.py --format <slug>      # another format
    ./mkusage.py --refresh            # ignore the cache

Format slugs seen on the site:
    gen9championsvgc2026regmc   Regulation M-C (Showdown)
    gen9championsvgc2026regmb   Regulation M-B
    battledataregmbs3           Regulation M-B S3 in-game ranked
    championstournaments        tournament results
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
CACHE = os.path.join(HERE, ".cache", "usage")
OUT = os.path.join(HERE, "data", "usage.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

REFRESH = "--refresh" in sys.argv
FORMAT = "gen9championsvgc2026regmc"
if "--format" in sys.argv:
    FORMAT = sys.argv[sys.argv.index("--format") + 1]


def fetch(path, delay=0.4):
    key = re.sub(r"[^a-z0-9]+", "_", path.lower()).strip("_") + ".html"
    dest = os.path.join(CACHE, key)
    if os.path.exists(dest) and not REFRESH:
        with open(dest, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    os.makedirs(CACHE, exist_ok=True)
    try:
        proc = subprocess.run(
            ["curl", "-sS", "-m", "40", "-A", UA, "--compressed", BASE + path],
            capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return ""
    if proc.returncode != 0:
        return ""
    body = proc.stdout.decode("utf-8", errors="ignore")
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(body)
    time.sleep(delay)
    return body


def faq_answers(page):
    """The FAQPage JSON-LD block, as {question: answer}."""
    for blob in re.findall(
            r'<script type="application/ld\+json"[^>]*>(.*?)</script>', page, re.S):
        try:
            data = json.loads(blob)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and data.get("@type") == "FAQPage":
            return {q.get("name", ""): q.get("acceptedAnswer", {}).get("text", "")
                    for q in data.get("mainEntity", [])}
    return {}


def pairs(text):
    """Pull name/percentage pairs out of an FAQ sentence.

    Two shapes appear depending on the format: "Dragon Claw (89.4%)" and
    "Fake Out 56.51%". The leading clause has to go first, or the first name
    comes back as the whole of "The top moves for Rillaboom in ... are Fake Out".
    """
    body = text
    cut = re.search(r"\bare\b\s*", body)
    if cut:
        body = body[cut.end():]
    # Drop the trailing commentary sentence.
    body = re.split(r"\.\s+[A-Z]", body)[0]

    out = []
    for chunk in re.split(r",|\band\b", body):
        chunk = chunk.strip().rstrip(".").strip()
        if not chunk:
            continue
        match = re.match(r"^(.+?)\s*\(?(\d+(?:\.\d+)?)%\)?$", chunk)
        if not match:
            continue
        name = match.group(1).strip().strip("(").strip()
        if name and name[0].isupper():
            out.append({"name": name, "percent": round(float(match.group(2)), 2)})
    return out


def parse_roster(page):
    """Pokemon in this format, with overall usage, in usage order.

    Rows are anchor plus percentage, but the percentage sits a variable distance
    away, so the page is split on the anchors and each slice searched forward.
    """
    anchors = list(re.finditer(
        r'/pokedex/' + re.escape(FORMAT) + r'/([A-Za-z0-9\-\'\.]+)"', page))
    entries, seen = [], set()
    for index, match in enumerate(anchors):
        name = match.group(1)
        if name in seen:
            continue
        end = anchors[index + 1].start() if index + 1 < len(anchors) else len(page)
        slice_ = page[match.end():end]
        found = re.search(r"(\d{1,3}(?:\.\d{1,3})?)\s*%", slice_)
        if not found:
            continue
        seen.add(name)
        entries.append({"slug": name, "usage": round(float(found.group(1)), 2)})
    return entries


def parse_detail(slug):
    page = fetch("/pokedex/%s/%s" % (FORMAT, slug))
    if not page:
        return None
    answers = faq_answers(page)
    record = {"moves": [], "items": [], "abilities": [], "teammates": [],
              "winrate": None, "wins": None, "losses": None}

    for question, answer in answers.items():
        lower = question.lower()
        if "best moves" in lower:
            record["moves"] = pairs(answer)
        elif "item should i use" in lower:
            record["items"] = pairs(answer)
        elif "ability is best" in lower:
            record["abilities"] = pairs(answer)
        elif "best teammates" in lower:
            # Percentages come through as "undefined" here, so keep the order.
            record["teammates"] = [
                n.strip() for n in
                re.findall(r"([A-Z][A-Za-z0-9'\-\.]*(?:-[A-Z][A-Za-z]*)?)\s*\(",
                           answer)]
        elif "winrate" in lower:
            rate = re.search(r"(\d+(?:\.\d+)?)%\s*winrate", answer)
            record_counts = re.search(r"(\d[\d,]*)\s*wins and\s*(\d[\d,]*)\s*losses",
                                      answer)
            if rate:
                record["winrate"] = float(rate.group(1))
            if record_counts:
                record["wins"] = int(record_counts.group(1).replace(",", ""))
                record["losses"] = int(record_counts.group(2).replace(",", ""))
    return record


def main():
    print("==> format %s" % FORMAT)
    listing = fetch("/pokedex/%s" % FORMAT)
    if not listing:
        print("could not fetch the format listing")
        return 1
    roster = parse_roster(listing)
    print("    %d Pokémon with usage" % len(roster))
    if not roster:
        return 1

    out = []
    for index, entry in enumerate(roster, 1):
        detail = parse_detail(entry["slug"])
        if detail is None:
            print("  ! %s" % entry["slug"])
            continue
        detail.update(entry)
        out.append(detail)
        if index % 15 == 0 or index == len(roster):
            print("    %d/%d" % (index, len(roster)))

    payload = {
        "format": FORMAT,
        "source": "https://www.pikalytics.com/pokedex/%s" % FORMAT,
        "license": "CC BY-NC 4.0",
        "generated": time.strftime("%Y-%m-%d"),
        "entries": out,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, ensure_ascii=False)

    withMoves = sum(1 for e in out if e["moves"])
    withItems = sum(1 for e in out if e["items"])
    print("==> wrote %s" % OUT)
    print("    %d entries, %d with moves, %d with items, %d with a winrate"
          % (len(out), withMoves, withItems,
             sum(1 for e in out if e["winrate"] is not None)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
