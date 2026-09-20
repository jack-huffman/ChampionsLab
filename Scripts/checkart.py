#!/usr/bin/env python3
"""Check that every Pokemon in the dex has every picture the app can draw.

There are two sets and they come from different places, so they are checked
differently:

  the illustrations   bundled, under data/sprites -- one per form, and the
                      shiny of each under data/sprites/shiny. These are files
                      on disk and the check is a directory listing.

  the pixel sprites   Showdown's, fetched the first time a form is wanted in
                      that style and kept under Application Support. Nothing
                      is bundled, so the check is whether the URL answers:
                      front and back, animated or still, ordinary and shiny.

The second half talks to play.pokemonshowdown.com, a few hundred forms at a
time, and caches what it learns in build/artcheck.json so a re-run is quick.

    ./Scripts/checkart.py            both halves
    ./Scripts/checkart.py --local    the bundled art only, no network
    ./Scripts/checkart.py --fresh    ignore the cache
"""

import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(HERE, "data", "sprites")
CACHE = os.path.join(HERE, "build", "artcheck.json")
BASE = "https://play.pokemonshowdown.com/sprites/"


def forms():
    with open(os.path.join(HERE, "data", "champions.json"), encoding="utf-8") as fh:
        return json.load(fh)["forms"]


def slug(showdown, suffix):
    """What Showdown calls the file, matching PixelSprites.slug in the app.

    The hyphen usually joins a species to a forme, but in Kommo-o it is part
    of the name. A form with no suffix here has no forme, so there is nothing
    to split off and the whole thing is squashed.
    """
    if not showdown:
        return None
    def ident(text):
        return "".join(c for c in text.lower() if c.isalnum())
    if not suffix:
        return ident(showdown)
    if "-" not in showdown:
        return ident(showdown)
    head, _, tail = showdown.partition("-")
    return ident(head) + "-" + ident(tail)


def check_local(roster):
    print("== the illustrations, bundled ==")
    have = set(os.listdir(SPRITES)) if os.path.isdir(SPRITES) else set()
    shiny_dir = os.path.join(SPRITES, "shiny")
    have_shiny = set(os.listdir(shiny_dir)) if os.path.isdir(shiny_dir) else set()
    missing, missing_shiny = [], []
    for form in roster:
        name = form["icon"] + ".png"
        if name not in have:
            missing.append(form["form_label"])
        if name not in have_shiny:
            missing_shiny.append(form["form_label"])
    total = len(roster)
    print("   %d of %d forms have their art" % (total - len(missing), total))
    print("   %d of %d forms have a shiny" % (total - len(missing_shiny), total))
    for label, rows in (("no art", missing), ("no shiny", missing_shiny)):
        if rows:
            print("   %s for %d: %s" % (label, len(rows), ", ".join(sorted(rows)[:12])))
    return not missing and not missing_shiny


class Unreachable(Exception):
    """Showdown could not be asked, which is not the same as it saying no."""


def status(url):
    """The HTTP code, through curl.

    curl rather than urllib because the Python here has no certificate bundle
    and urllib cannot complete the handshake -- which it reports as an error
    indistinguishable, to a careless caller, from a 404. That distinction is
    the whole value of this script: "Showdown has not drawn this" and "we
    could not ask Showdown" are opposite findings and the first run of this
    conflated them, reporting that every sprite in the game was missing.
    """
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "25",
         "--retry", "2", "-I", url],
        capture_output=True, text=True, check=False)
    code = out.stdout.strip()
    if code in ("000", ""):
        raise Unreachable(url)
    return int(code)


def one(name):
    """Whether Showdown has this sprite anywhere: the Gen 6 animated set, the
    Gen 5 one behind it, or a still. The same order the app asks in."""
    for path in name:
        code = status(BASE + path)
        if code == 200:
            return True
        if code != 404:
            raise Unreachable(BASE + path)
    return False


def check_showdown(roster, fresh):
    print("\n== the pixel sprites, Showdown's ==")
    cache = {}
    if not fresh and os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as fh:
            cache = json.load(fh)

    wanted, named = {}, 0
    for form in roster:
        piece = slug(form.get("showdown"), form.get("suffix"))
        if not piece:
            continue
        named += 1
        for kind, dirs in (
                ("front", ("ani/", "gen5ani/", "gen5/")),
                ("front shiny", ("ani-shiny/", "gen5ani-shiny/", "gen5-shiny/")),
                ("back", ("ani-back/", "gen5ani-back/", "gen5-back/")),
                ("back shiny", ("ani-back-shiny/", "gen5ani-back-shiny/", "gen5-back-shiny/"))):
            wanted[(form["form_label"], piece, kind)] = tuple(
                d + piece + (".png" if d.startswith("gen5/") or d.startswith("gen5-") else ".gif")
                for d in dirs)
    print("   %d of %d forms carry a Showdown name" % (named, len(roster)))

    todo = [k for k in wanted if "|".join(k[1:]) not in cache]
    if todo:
        print("   asking Showdown about %d sprites (%d already known)"
              % (len(todo), len(wanted) - len(todo)))
        def ask(key):
            try:
                return one(wanted[key])
            except Unreachable as why:
                return why

        failures = []
        with ThreadPoolExecutor(max_workers=12) as pool:
            for key, answer in zip(todo, pool.map(ask, todo)):
                if isinstance(answer, Unreachable):
                    failures.append(str(answer))
                    continue
                cache["|".join(key[1:])] = answer
        if failures:
            print("   could not reach Showdown for %d of them -- that is a"
                  " broken connection, not missing art" % len(failures))
            print("        first: %s" % failures[0])
            if len(failures) == len(todo):
                print("   nothing was learned; not writing the cache")
                return False
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "w", encoding="utf-8") as fh:
            json.dump(cache, fh, indent=1, sort_keys=True)

    by_kind, unknown = {}, 0
    for (label, piece, kind) in wanted:
        answer = cache.get("|".join((piece, kind)))
        if answer is None:
            unknown += 1
            continue
        by_kind.setdefault(kind, []).append((label, answer))
    if unknown:
        print("   %d were never answered and are counted as neither" % unknown)
    whole = True
    for kind in ("front", "front shiny", "back", "back shiny"):
        rows = by_kind.get(kind, [])
        gone = sorted(label for label, ok in rows if not ok)
        print("   %-12s %d of %d" % (kind, len(rows) - len(gone), len(rows)))
        if gone:
            whole = False
            print("        missing %d: %s" % (len(gone), ", ".join(gone[:10])
                                              + ("..." if len(gone) > 10 else "")))
    # The question that actually matters: is the shiny set as complete as the
    # ordinary one? A form Showdown has never drawn is not a gap this app can
    # close; a form it drew plain and not shiny would be.
    for plain, shiny in (("front", "front shiny"), ("back", "back shiny")):
        have_plain = {label for label, ok in by_kind.get(plain, []) if ok}
        have_shiny = {label for label, ok in by_kind.get(shiny, []) if ok}
        short = sorted(have_plain - have_shiny)
        print("   %s but no %s: %d%s"
              % (plain, shiny, len(short), (" -- " + ", ".join(short[:8])) if short else ""))
    return whole


def main():
    fresh = "--fresh" in sys.argv
    roster = forms()
    local = check_local(roster)
    if "--local" in sys.argv:
        return 0 if local else 1
    remote = check_showdown(roster, fresh)
    print("\n%s" % ("every picture is there" if local and remote
                    else "see the gaps above"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
