#!/usr/bin/env python3
"""Build data/champions.json — the bundled Regulation M-C dataset.

Serebii keeps a Champions-specific Pokedex and Attackdex, which is what makes
this worth scraping rather than using PokeAPI: PokeAPI has no idea Mega
Golisopod is Bug/Steel with Tough Claws, because that form only exists in
Champions. Everything competitive comes from there:

    /pokedex-champions/stat/all.shtml   the legal roster, one row per *form*
    /pokedex-champions/<slug>/          abilities, learnset, per-form stats
    /attackdex-champions/<move>.shtml   power, accuracy, target, contact flags

Raw HTML is cached under .cache/ so re-runs cost nothing and a failed run
resumes where it stopped. The generated JSON is committed, so a clean checkout
builds without network access — the app never scrapes at runtime.

    ./mkdata.py                # incremental, uses cache
    ./mkdata.py --refresh      # re-fetch everything
    ./mkdata.py --only-roster  # roster + abilities, skip the slow move pass
"""

import html
import json
import os
import re
import subprocess
import sys
import time

BASE = "https://www.serebii.net"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
OUT = os.path.join(HERE, "data", "champions.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# Serebii prints the 18 type multipliers in this column order, unlabelled.
TYPE_ORDER = ["Normal", "Fire", "Water", "Electric", "Grass", "Ice", "Fighting",
              "Poison", "Ground", "Flying", "Psychic", "Bug", "Rock", "Ghost",
              "Dragon", "Dark", "Steel", "Fairy"]

# Icon suffixes a Mega form can carry. Ambiguous on its own — Rotom-Mow and
# Lycanroc-Midnight are also "-m" — so it is only trusted when the species page
# actually printed a Mega card.
MEGA_SUFFIXES = {"m", "mx", "my", "mz"}

# Serebii titles every regional form by its plain species name, so the icon
# suffix is the only thing that distinguishes them. Keyed "species:suffix"
# because the letters are reused: "-a" is Alolan on Ninetales but Aqua on
# Tauros, and "-m" is Mow on Rotom but Male on Meowstic.
FORM_NAMES = {
    "aegislash:b": "%s (Blade)",
    "arcanine:h": "Hisuian %s", "avalugg:h": "Hisuian %s",
    "decidueye:h": "Hisuian %s", "goodra:h": "Hisuian %s",
    "samurott:h": "Hisuian %s", "typhlosion:h": "Hisuian %s",
    "zoroark:h": "Hisuian %s",
    "floette:e": "%s (Eternal)",
    "gourgeist:s": "%s (Small)", "gourgeist:l": "%s (Large)",
    "gourgeist:h": "%s (Super)",
    "indeedee:f": "%s (Female)",
    "lycanroc:d": "%s (Dusk)", "lycanroc:m": "%s (Midnight)",
    "meowstic:f": "%s (Female)",  # "-m" here is Mega Meowstic, not the male form
    "ninetales:a": "Alolan %s", "raichu:a": "Alolan %s",
    "rotom:f": "%s (Wash)", "rotom:h": "%s (Heat)",
    "rotom:m": "%s (Mow)", "rotom:s": "%s (Fan)",
    "slowbro:g": "Galarian %s", "slowking:g": "Galarian %s",
    "stunfisk:g": "Galarian %s",
    "tauros:a": "Paldean %s (Aqua)", "tauros:b": "Paldean %s (Blaze)",
    "tauros:p": "Paldean %s (Combat)",
    "toxtricity:l": "%s (Low Key)",
}

REFRESH = "--refresh" in sys.argv
ONLY_ROSTER = "--only-roster" in sys.argv


def curl(url):
    """Fetch bytes with the system curl.

    Not urllib: this machine's Python trusts a certificate chain that Serebii's
    does not chain to, so urllib raises CERTIFICATE_VERIFY_FAILED where curl,
    using the system keychain, succeeds.
    """
    try:
        proc = subprocess.run(
            ["curl", "-sS", "-m", "40", "-A", UA, "--compressed", url],
            capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return b""
    return proc.stdout if proc.returncode == 0 else b""


def fetch(path, delay=0.25):
    """GET a Serebii page, caching the body under .cache/."""
    key = re.sub(r"[^a-z0-9]+", "_", path.lower()).strip("_") + ".html"
    dest = os.path.join(CACHE, key)
    if os.path.exists(dest) and not REFRESH:
        with open(dest, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    os.makedirs(CACHE, exist_ok=True)
    body = ""
    for attempt in range(3):
        blob = curl(BASE + path)
        if blob:
            body = blob.decode("utf-8", errors="ignore")
            break
        if attempt == 2:
            print("  ! %s: fetch failed" % path)
            return ""
        time.sleep(1.5 * (attempt + 1))
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(body)
    time.sleep(delay)  # be a good citizen; Serebii is someone's hobby server
    return body


def text_of(fragment):
    """Collapse an HTML fragment to single-spaced text."""
    out = html.unescape(re.sub(r"<[^>]+>", " ", fragment))
    return re.sub(r"\s+", " ", out).strip()


def slug_of(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


# ---------------------------------------------------------------- roster ----

def parse_roster():
    """Every legal form, from the all-stats listing.

    One row per form, so Charizard appears three times (base, Mega X, Mega Y).
    The icon filename is what distinguishes them: 006.png, 006-mx, 006-my.
    """
    page = fetch("/pokedex-champions/stat/all.shtml")
    blocks = re.split(r"<!--<td class=\"cen\">\s*\d+ / \d+\s*</td>-->", page)[1:]
    forms = []
    for block in blocks:
        num = re.search(r"#(\d{4})", block)
        name = re.search(r'<a href="/pokedex-champions/[^"]+/">([^<]+)</a>', block)
        slug = re.search(r'href="/pokedex-champions/([^"/]+)/"', block)
        icon = re.search(r"/pokedex-champions/icon/([^\"]+)\.png", block)
        types = re.findall(r"/pokedex-bw/type/([a-z]+)\.gif", block)
        stats = re.findall(r'<td align="center" class="fooinfo">(\d{1,3})</td>', block)
        if not (num and name and slug and len(stats) >= 6):
            continue
        icon_name = icon.group(1) if icon else ""
        suffix = ""
        if "-" in icon_name:
            suffix = icon_name.split("-", 1)[1]  # m, mx, my, mz, and form ids
        forms.append({
            "dex": int(num.group(1)),
            "species": slug.group(1),
            "name": html.unescape(name.group(1)).strip(),
            "icon": icon_name,
            "suffix": suffix,
            "types": [t.capitalize() for t in types[:2]],
            "stats": [int(s) for s in stats[:6]],
        })
    return forms


# --------------------------------------------------------------- species ----

def split_form_sections(page):
    """Serebii stacks every form's card into one page; cut them apart.

    Each card opens with a 'Name | Other Names | No. | Type' header row, so the
    offsets of 'Other Names' are the section starts. Golisopod's page yields two:
    the base form and Mega Golisopod, each owning the abilities, resistances and
    stats that follow it.
    """
    marks = [m.start() for m in re.finditer(r"Other Names", page)]
    if not marks:
        return [page]
    bounds = marks + [len(page)]
    return [page[bounds[i]:bounds[i + 1]] for i in range(len(marks))]


def parse_form_label(section):
    """The form's display name, first cell after the header row."""
    m = re.search(r'<td class="fooinfo">\s*([A-Za-z][^<]{1,40}?)\s*</td>', section)
    if not m:
        return ""
    # "Mega  Golisopod" comes through with the double space Serebii emits.
    return re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()


def parse_abilities(section):
    """Ability names and their in-game descriptions from one form's card.

    Serebii wraps the link text in <b>, and prints each ability twice: once in
    the 'Abilities:' header and once with its description below it.
    """
    out, seen = [], set()
    for m in re.finditer(r'<a href="/abilitydex/[^"]+\.shtml">\s*<b>([^<]+)</b>\s*</a>', section):
        name = re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()
        if name and name not in seen:
            seen.add(name)
            out.append({"name": name, "desc": ""})
    body = text_of(section)
    for ability in out:
        hit = re.search(
            re.escape(ability["name"]) + r"\s*:\s*([A-Z].{10,400}?)(?=\s*(?:Damage Taken|Weakness|Stats|Evolutionary Chain|$))",
            body)
        if hit:
            ability["desc"] = re.sub(r"\s+", " ", hit.group(1)).strip()
    return out


def parse_damage_taken(section):
    """The 18 incoming-damage multipliers, in Serebii's fixed column order.

    Mega cards head this table 'Damage Taken'; base cards head it 'Weakness'.
    """
    idx = section.find("Damage Taken")
    if idx < 0:
        idx = section.find("Weakness")
    if idx < 0:
        return {}
    chunk = section[idx:idx + 8000]
    mults = re.findall(r"\*\s*([\d.]+)", chunk)
    if len(mults) < 18:
        return {}
    return {t: float(v) for t, v in zip(TYPE_ORDER, mults[:18])}


def parse_learnset(page):
    """Move names this species can use, from every move table on the page."""
    moves = set()
    for m in re.finditer(r'<a href="/attackdex-champions/([a-z0-9\-\']+)\.shtml">([^<]+)</a>', page):
        label = html.unescape(m.group(2)).strip()
        if label and not label.startswith("Details"):
            moves.add((m.group(1), label))
    return sorted(moves)


def parse_species(slug):
    page = fetch("/pokedex-champions/%s/" % slug)
    if not page:
        return None, []
    sections = split_form_sections(page)
    forms = []
    for section in sections:
        forms.append({
            "label": parse_form_label(section),
            "abilities": parse_abilities(section),
            "damage_taken": parse_damage_taken(section),
        })
    return forms, parse_learnset(page)


# ----------------------------------------------------------------- moves ----

TARGET_WORDS = ["All Adjacent Foes", "All Adjacent Pokémon", "All Adjacent Pokemon",
                "Selected Target", "Random Adjacent Foe", "User", "All Pokémon",
                "All Pokemon", "Both Foes", "One Ally", "User and Allies",
                "All Allies", "Entire Field", "Foe's Field", "User's Field"]

# The flag table prints five label cells, then five Yes/No cells, three times
# over. Names are normalised to these keys as they are read positionally.
FLAG_KEYS = {
    "physicalcontact": "contact",
    "soundtype": "sound",
    "punchmove": "punch",
    "bitingmove": "bite",
    "snatchable": "snatchable",
    "slicingmove": "slicing",
    "bullettype": "bullet",
    "windmove": "wind",
    "powdermove": "powder",
    "metronome": "metronome",
    "affectedbygravity": "gravity",
    "defrostswhenused": "defrosts",
    "reflectedbymagiccoatmagicbounce": "reflectable",
    "blockedbyprotectdetect": "protectable",
    "copyablebymirrormove": "copyable",
}


def flag_key(label):
    """Map a flag cell's text to a stable key.

    Half the labels carry a trailing "- Details" link to the ability they
    interact with ("Sound-Type - Details"), and the rest carry punctuation, so
    match on letters alone rather than the literal cell text.
    """
    norm = re.sub(r"[^a-z]", "", label.lower())
    norm = re.sub(r"details$", "", norm)
    return FLAG_KEYS.get(norm)


def parse_move_flags(page):
    """Read the Yes/No flag grid.

    It is laid out as alternating rows — five <td class="fooevo"> labels, then
    five <td class="cen"> values — so the flags have to be paired positionally.
    Reading the flattened text instead makes every move look like a contact
    move, because the label "Physical Contact" is present whether it is Yes or No.
    """
    start = page.find("Physical Contact")
    if start < 0:
        return {}
    table_start = page.rfind("<table", 0, start)
    table_end = page.find("</table>", start)
    if table_start < 0 or table_end < 0:
        return {}
    table = page[table_start:table_end]

    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", table, re.S)
    flags = {}
    pending = []
    for row in rows:
        labels = re.findall(r'<td[^>]*class="fooevo"[^>]*>(.*?)</td>', row, re.S)
        values = re.findall(r'<td[^>]*class="cen"[^>]*>(.*?)</td>', row, re.S)
        if labels:
            pending = [re.sub(r"\s+", " ", text_of(l)).strip() for l in labels]
        elif values and pending:
            for label, value in zip(pending, values):
                key = flag_key(label)
                if key:
                    flags[key] = text_of(value).strip().lower().startswith("yes")
            pending = []
    return flags


def parse_move(slug, label):
    page = fetch("/attackdex-champions/%s.shtml" % slug, delay=0.15)
    if not page:
        return None
    table = None
    for m in re.finditer(r'class="dextable"', page):
        seg = page[m.start():m.start() + 6000]
        if "Base Power" in seg or "Battle Effect" in seg:
            table = seg
            break
    if table is None:
        return None
    body = text_of(table)

    mtype = re.search(r"/pokedex-bw/type/([a-z]+)\.gif", table)
    cat = re.search(r"/(?:pokedex-bw|pokedex-sm|games)/(?:type/)?(physical|special|other)\.(?:gif|png)", table, re.I)

    power, acc, pp = 0, 0, 0
    trio = re.search(r"Power Points\s*Base Power\s*Accuracy\s*(\S+)\s+(\S+)\s+(\S+)", body)
    if trio:
        pp = int(trio.group(1)) if trio.group(1).isdigit() else 0
        power = int(trio.group(2)) if trio.group(2).isdigit() else 0
        acc = int(trio.group(3)) if trio.group(3).isdigit() else 0
    # Serebii writes 101 for a move that skips the accuracy check entirely.
    # Store that as 0 and let the app render it as "—".
    never_misses = acc > 100
    if never_misses:
        acc = 0

    prio = re.search(r"Speed Priority\s*Pok[eé]mon Hit in Battle\s*[\d.]+%\s*(-?\d+)", body)
    if not prio:
        prio = re.search(r"Speed Priority[^\d\-]*(-?\d+)", body)

    target = ""
    for word in TARGET_WORDS:
        if word in body:
            target = word.replace("Pokemon", "Pokémon")
            break

    effect = re.search(r"Battle Effect:\s*(.+?)\s*(?:Secondary Effect|Base Critical|$)", body)
    rate = re.search(r"Effect Rate:\s*([\d.]+)\s*%", body)
    crit = re.search(r"Base Critical Hit Rate\s*.*?([\d.]+)\s*%", body)

    return {
        "id": slug,
        "name": label,
        "type": mtype.group(1).capitalize() if mtype else "Normal",
        "category": cat.group(1).capitalize() if cat else "Other",
        "power": power,
        "accuracy": acc,
        "never_misses": never_misses,
        "pp": pp,
        "priority": int(prio.group(1)) if prio else 0,
        "target": target or "Selected Target",
        "crit_rate": float(crit.group(1)) if crit else 0.0,
        "flags": parse_move_flags(page),
        "effect": (effect.group(1).strip() if effect else "")[:500],
        "effect_rate": float(rate.group(1)) if rate else 0.0,
    }


# ----------------------------------------------------------------- items ----

def parse_item_index():
    """Every hold item Serebii lists, as slug -> display name."""
    page = fetch("/itemdex/list/holditem.shtml")
    found = {}
    for m in re.finditer(r'href="/itemdex/([a-z0-9\-\']+)\.shtml"[^>]*>([^<]{2,40})</a>', page):
        slug, label = m.group(1), html.unescape(m.group(2)).strip()
        if label:
            found.setdefault(slug, label)
    return found


def parse_item(slug, label):
    page = fetch("/itemdex/%s.shtml" % slug, delay=0.15)
    if not page:
        return None
    body = text_of(page)
    effect = re.search(r"In-Depth Effect\s*(.+?)\s*(?:Flavour Text|Locations|$)", body)
    fling = re.search(r"Fling Damage\s*Price.*?Hold Item\s*\S+.*?\s(\d{1,3})\s", body)
    return {
        "name": label,
        "slug": slug,
        "effect": re.sub(r"\s+", " ", effect.group(1)).strip()[:600] if effect else "",
        "fling": int(fling.group(1)) if fling else 0,
    }


def parse_move_index():
    """Every move in the Champions Attackdex, not just the ones in learnsets.

    The index is a jump-to <select>, not a list of links, and a few slugs carry
    commas ("10,000,000voltthunderbolt"), so match the option values loosely.
    """
    page = fetch("/attackdex-champions/")
    found = {}
    for m in re.finditer(
            r'<option value="/attackdex-champions/([^"]+)\.shtml">([^<]+)</option>', page):
        slug, label = m.group(1), html.unescape(m.group(2)).strip()
        if label and not label.lower().startswith("attackdex"):
            found.setdefault(slug, label)
    return found


# ------------------------------------------------------------------ main ----

def main():
    print("==> roster")
    roster = parse_roster()
    print("    %d legal forms" % len(roster))

    species_slugs = sorted({f["species"] for f in roster})
    print("==> species pages (%d)" % len(species_slugs))
    learnsets, detail = {}, {}
    for i, slug in enumerate(species_slugs, 1):
        forms, moves = parse_species(slug)
        if forms is None:
            continue
        detail[slug] = forms
        learnsets[slug] = moves
        if i % 25 == 0 or i == len(species_slugs):
            print("    %d/%d" % (i, len(species_slugs)))

    # Attach abilities and resistances by pairing roster rows to page cards.
    #
    # Label matching cannot do this: Serebii titles both of Garchomp's Mega
    # cards "Mega Garchomp", dropping the Z. Order is reliable though — the
    # original Mega is printed before the Z one, and X before Y — and the icon
    # suffixes sort the same way (m < mx < my < mz), so zipping the two
    # sequences lines Levitate up with 445-mz rather than 445-m.
    by_species = {}
    for form in roster:
        by_species.setdefault(form["species"], []).append(form)

    for slug, rows in by_species.items():
        cards = detail.get(slug, [])
        mega_cards = [c for c in cards if c["label"].lower().startswith("mega")]
        base_cards = [c for c in cards if not c["label"].lower().startswith("mega")]
        # A bare "-m" suffix is not proof of a Mega: Rotom-Mow and Lycanroc-Midnight
        # use it too. Only treat it as one when the page actually printed a Mega card.
        is_mega = (lambda r: r["suffix"] in MEGA_SUFFIXES and bool(mega_cards))
        mega_rows = sorted([r for r in rows if is_mega(r)], key=lambda r: r["suffix"])
        base_rows = sorted([r for r in rows if not is_mega(r)],
                           key=lambda r: r["suffix"])
        for group_rows, group_cards in ((base_rows, base_cards), (mega_rows, mega_cards)):
            for i, row in enumerate(group_rows):
                card = group_cards[i] if i < len(group_cards) else (
                    group_cards[-1] if group_cards else None)
                if card is None:
                    card = cards[0] if cards else None
                row["abilities"] = card["abilities"] if card else []
                row["damage_taken"] = card["damage_taken"] if card else {}
                row["form_label"] = (card["label"] if card else row["name"]) or row["name"]

    # Serebii titles every Mega card "Mega <species>" and every regional form
    # by its plain species name, so the icon suffix is the only thing telling
    # them apart. Rebuild a display name from it.
    for form in roster:
        form.setdefault("abilities", [])
        label = form.get("form_label") or form["name"]
        suffix = form["suffix"]
        if suffix in MEGA_SUFFIXES and label.lower().startswith("mega"):
            tag = {"mx": "X", "my": "Y", "mz": "Z"}.get(suffix)
            if tag and not label.rstrip().endswith(tag):
                label = "%s %s" % (label.rstrip(), tag)
        else:
            pattern = FORM_NAMES.get("%s:%s" % (form["species"], suffix))
            if pattern:
                label = pattern % form["name"]
        form["form_label"] = label
        form["moves"] = [m[0] for m in learnsets.get(form["species"], [])]
        form.pop("damage_taken", None)  # recomputed from types in the app

    moves = {}
    if not ONLY_ROSTER:
        # Start from the full Attackdex so the reference is complete, then add
        # anything a learnset mentions that the index happened to miss.
        wanted = parse_move_index()
        for slug in species_slugs:
            for mid, label in learnsets.get(slug, []):
                wanted.setdefault(mid, label)
        # Anything no legal Pokémon can actually use (Z-moves, Max moves) stays
        # in the reference but is flagged so the team builder never offers it.
        learnable = {mid for slug in species_slugs
                     for mid, _ in learnsets.get(slug, [])}
        print("==> move pages (%d)" % len(wanted))
        for i, (mid, label) in enumerate(sorted(wanted.items()), 1):
            parsed = parse_move(mid, label)
            if parsed:
                parsed["learnable"] = mid in learnable
                moves[mid] = parsed
            if i % 100 == 0 or i == len(wanted):
                print("    %d/%d" % (i, len(wanted)))

    print("==> sprites")
    sprite_dir = os.path.join(HERE, "data", "sprites")
    os.makedirs(sprite_dir, exist_ok=True)
    got = 0
    for form in roster:
        icon = form["icon"]
        if not icon:
            continue
        dest = os.path.join(sprite_dir, icon + ".png")
        if os.path.exists(dest) and not REFRESH:
            got += 1
            continue
        blob = curl(BASE + "/pokedex-champions/icon/%s.png" % icon)
        if not blob:
            print("  ! sprite %s" % icon)
            continue
        with open(dest, "wb") as fh:
            fh.write(blob)
        got += 1
        time.sleep(0.1)
    print("    %d sprites" % got)

    overlay_path = os.path.join(HERE, "data", "overlay.json")
    with open(overlay_path, encoding="utf-8") as fh:
        overlay = json.load(fh)

    # Scrape the whole hold-item list for the reference, then layer the curated
    # entries on top — those carry the M-C "new" marker and the competitive note,
    # neither of which Serebii has any reason to know about.
    items = []
    if not ONLY_ROSTER:
        index = parse_item_index()
        print("==> item pages (%d)" % len(index))
        for i, (slug, label) in enumerate(sorted(index.items()), 1):
            parsed = parse_item(slug, label)
            if parsed:
                items.append(parsed)
            if i % 100 == 0 or i == len(index):
                print("    %d/%d" % (i, len(index)))
    curated = {c["name"]: c for c in overlay["items"]}
    for item in items:
        extra = curated.pop(item["name"], None)
        if extra:
            item["new"] = extra.get("new", False)
            item["category"] = extra.get("category", "")
            item["note"] = extra.get("note", "")
            if extra.get("effect"):
                item["short"] = extra["effect"]
    for leftover in curated.values():  # curated entries Serebii does not list
        items.append({"name": leftover["name"], "slug": slug_of(leftover["name"]),
                      "effect": leftover.get("effect", ""), "fling": 0,
                      "new": leftover.get("new", False),
                      "category": leftover.get("category", ""),
                      "note": leftover.get("note", ""),
                      "short": leftover.get("effect", "")})
    items.sort(key=lambda i: i["name"])

    # One ability table for the whole dex, keyed by name. Descriptions come off
    # the species cards, where Serebii prints them in full.
    abilities = {}
    for form in roster:
        for ability in form["abilities"]:
            name, desc = ability["name"], ability["desc"]
            if name not in abilities or (desc and not abilities[name]["desc"]):
                abilities[name] = {"name": name, "desc": desc, "users": []}
    for form in roster:
        for ability in form["abilities"]:
            abilities[ability["name"]]["users"].append(form["form_label"])
    for entry in abilities.values():
        entry["users"] = sorted(set(entry["users"]))

    out = {
        "regulation": overlay["regulation"],
        "rules": overlay["rules"],
        "items": items,
        "usage": overlay["usage"],
        "notes": overlay["notes"],
        "forms": roster,
        "moves": moves,
        "abilities": abilities,
        "generated": time.strftime("%Y-%m-%d"),
        "sources": [
            "https://www.serebii.net/pokedex-champions/",
            "https://www.serebii.net/attackdex-champions/",
            "https://victoryroad.pro/champions-regulations/",
            "https://www.pokemon.com/us/news/get-ready-for-regulation-set-m-c-in-pokemon-champions",
        ],
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(out, fh, separators=(",", ":"), ensure_ascii=False)
    print("==> wrote %s (%.1f MB)" % (OUT, os.path.getsize(OUT) / 1e6))
    print("    %d forms, %d moves, %d abilities, %d items"
          % (len(roster), len(moves), len(abilities), len(items)))

    # Serebii was still filling in the Champions dex when M-C went live, so say
    # plainly which of the new arrivals have not landed yet. Re-run to pick them
    # up as they appear rather than guessing at their stats.
    have = {f["name"] for f in roster}
    absent = [n for n in overlay["regulation"]["new_pokemon"]
              if n.split(" (")[0] not in have]
    if absent:
        print("    note: %d M-C additions not yet in Serebii's dex — re-run later:"
              % len(absent))
        print("      " + ", ".join(absent))


if __name__ == "__main__":
    main()
