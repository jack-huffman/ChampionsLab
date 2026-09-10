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
    "rotom:f": "%s (Frost)", "rotom:h": "%s (Heat)",
    "rotom:m": "%s (Mow)", "rotom:s": "%s (Fan)",
    "rotom:w": "%s (Wash)",
    "slowbro:g": "Galarian %s", "slowking:g": "Galarian %s",
    "stunfisk:g": "Galarian %s",
    "tauros:a": "Paldean %s (Aqua)", "tauros:b": "Paldean %s (Blaze)",
    "tauros:p": "Paldean %s (Combat)",
    "toxtricity:l": "%s (Low Key)",
    "basculegion:f": "%s (Female)",
    "castform:r": "%s (Rainy)", "castform:s": "%s (Sunny)",
    "castform:i": "%s (Snowy)",
    "farfetch'd:g": "Galarian %s", "mr.mime:g": "Galarian %s",
    "maushold:f": "%s (Family of Four)",
    "palafin:h": "%s (Hero)",
    "persian:a": "Alolan %s",
    "squawkabilly:b": "%s (Blue Plumage)", "squawkabilly:w": "%s (White Plumage)",
    "squawkabilly:y": "%s (Yellow Plumage)",
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
    """Every legal form, unioned from the eighteen type listings.

    Not /pokedex-champions/stat/all.shtml, which looks like the obvious source
    and is a trap: it is sorted by base stat total and cut off at 300 rows, so
    everything below 465 BST silently vanishes. That quietly dropped Pelipper
    (430) and Politoed (500 — but only listed under Water), among others.

    The type pages have no such cap, and carry more per row: dex number, icon,
    name, types, abilities and the six stats. A dual-type Pokémon appears on
    both of its pages, so rows are deduplicated by icon — which is also what
    distinguishes forms, Charizard being 006, 006-mx and 006-my.
    """
    forms = {}
    for type_name in (t.lower() for t in TYPE_ORDER):
        page = fetch("/pokedex-champions/%s.shtml" % type_name)
        if not page:
            continue
        # Split on the dex number rather than <tr>: every row nests a
        # <table class="pkmn"><tr> around its sprite, so splitting on tags cuts
        # each entry in half and separates the number from its stats.
        marks = [m.start() for m in re.finditer(r"#\d{4}", page)] + [len(page)]
        for start, end in zip(marks, marks[1:]):
            block = page[start:end]
            num = re.search(r"#(\d{4})", block)
            icon = re.search(r"/pokedex-champions/icon/([^\"]+)\.png", block)
            name = re.search(r'<a href="/pokedex-champions/([^"/]+)/?">([^<]+)</a>', block)
            types = re.findall(r"/pokedex-bw/type/([a-z]+)\.gif", block)
            stats = re.findall(r'<td align="center" class="fooinfo">(\d{1,3})</td>', block)
            if not (num and icon and name and len(stats) >= 6):
                continue
            icon_name = icon.group(1)
            if icon_name in forms:
                continue
            suffix = icon_name.split("-", 1)[1] if "-" in icon_name else ""
            forms[icon_name] = {
                "dex": int(num.group(1)),
                "species": name.group(1),
                "name": html.unescape(name.group(2)).strip(),
                "icon": icon_name,
                "suffix": suffix,
                "types": [t.capitalize() for t in types[:2]],
                "stats": [int(s) for s in stats[:6]],
            }
    return sorted(forms.values(), key=lambda f: (f["dex"], f["suffix"]))


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


ABILITY_LINK = re.compile(
    r'<a href="/abilitydex/[^"]+\.shtml">\s*<b>([^<]+)</b>\s*</a>')

# The same link, but followed by the colon that introduces its description.
ABILITY_ENTRY = re.compile(
    r'<a href="/abilitydex/[^"]+\.shtml">\s*<b>([^<]+)</b>\s*</a>\s*:')


def clean_ability_text(desc):
    """Trim the sub-headers that share the abilities cell.

    A species with regional forms lists them all in the same <td>, introduced by
    headings like "Hisuian Form Abilities:" and "(Available) -->". Those land on
    the end of whichever description precedes them.
    """
    desc = re.sub(r"^\(?Available\)?\s*(?:--?>)?\s*", "", desc)
    desc = re.split(r"\s+(?:\w+\s+){0,2}Abilities\s*:", desc)[0]
    desc = re.split(r"\s*\(Available\)", desc)[0]
    return desc.strip().rstrip(":-\u2014> ").strip()


def parse_abilities(section):
    """Ability names and their in-game descriptions from one form's card.

    Every ability for a form shares a single <td>, separated by <br />, each
    written as "<a …><b>Name</b></a>: description". So a description runs until
    the next ability's link, and nothing else bounds it.

    Reading this off the flattened text does not work. An earlier version ended
    each description at the "Weakness" or "Damage Taken" heading instead, which
    meant every ability but the last swallowed the ones after it — Farigiraf's
    Armor Tail carried the text for Sap Sipper, and 99 of 214 abilities were
    wrong the same way.
    """
    # The header row lists the names; the cell below pairs each with its text.
    cell = None
    for m in re.finditer(r'<td[^>]*class="fooinfo"[^>]*>(.*?)</td>', section, re.S):
        if "/abilitydex/" in m.group(1) and ABILITY_ENTRY.search(m.group(1)):
            cell = m.group(1)
            break

    if cell is None:
        # No description cell on this card; keep the names from the header.
        out, seen = [], set()
        for m in ABILITY_LINK.finditer(section):
            name = re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()
            if name and name not in seen:
                seen.add(name)
                out.append({"name": name, "desc": ""})
        return out

    entries = list(ABILITY_ENTRY.finditer(cell))
    out, seen = [], set()
    for i, match in enumerate(entries):
        name = re.sub(r"\s+", " ", html.unescape(match.group(1))).strip()
        end = entries[i + 1].start() if i + 1 < len(entries) else len(cell)
        desc = text_of(cell[match.end():end])
        desc = clean_ability_text(desc)
        if name and name not in seen:
            seen.add(name)
            out.append({"name": name, "desc": desc})
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
    """Every hold item Serebii lists, as slug -> display name.

    Two lists, because Serebii files Mega Stones separately from ordinary hold
    items. They matter here: Champions requires a Mega to hold its stone, so the
    stone occupies the item slot and counts against the item clause — a Mega
    cannot also carry a Life Orb.
    """
    found = {}
    for path in ("/itemdex/list/holditem.shtml", "/itemdex/list/megastone.shtml"):
        page = fetch(path)
        for m in re.finditer(
                r'href="/itemdex/([a-z0-9\-\']+)\.shtml"[^>]*>([^<]{2,40})</a>', page):
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
                # Remember that this row is a Mega, so the display name can be
                # built from the species instead of trusting the card title —
                # Serebii titles Meganium's Mega card just "Meganium".
                row["_mega"] = (group_rows is mega_rows) and card is not None

    # Serebii titles every Mega card "Mega <species>" and every regional form
    # by its plain species name, so the icon suffix is the only thing telling
    # them apart. Rebuild a display name from it.
    for form in roster:
        form.setdefault("abilities", [])
        label = form.get("form_label") or form["name"]
        suffix = form["suffix"]
        if form.pop("_mega", False):
            # Serebii titles Meganium's Mega card just "Meganium", so build the
            # name from the species rather than trusting the card title.
            label = "Mega %s" % form["name"]
            tag = {"mx": "X", "my": "Y", "mz": "Z"}.get(suffix)
            if tag:
                label = "%s %s" % (label, tag)
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

    audit_abilities(abilities)

    assign_stones(roster, items)

    out = {
        "regulation": overlay["regulation"],
        "rules": overlay["rules"],
        "items": items,
        "usage": overlay["usage"],
        "meta_teams": overlay["meta_teams"],
        "predictions": overlay["predictions"],
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
    labels = {f["form_label"] for f in roster}
    absent = [n for n in overlay["regulation"]["new_pokemon"]
              if n.split(" (")[0] not in have]
    absent += [m for m in overlay["regulation"]["new_megas"] if m not in labels]
    if absent:
        print("    note: %d M-C additions not yet in Serebii's dex — re-run later:"
              % len(absent))
        print("      " + ", ".join(absent))

    audit_overlay(overlay, roster, moves, items)


def assign_stones(roster, items):
    """Tag each Mega form with the stone that triggers it.

    Champions registers the base Pokémon holding its stone — a team lists
    "Charizard @ Charizardite Y", not "Mega Charizard Y" — so the app needs the
    link to know that a slot will be a Mega in battle and to use the Mega's
    stats. Stone names follow the species closely enough to match on a prefix,
    with the X/Y/Z tag disambiguating Charizard's and Raichu's two forms.
    """
    names = [i["name"] for i in items]
    tags = {"mx": "X", "my": "Y", "mz": "Z"}
    matched, unmatched = 0, []
    for form in roster:
        form["stone"] = ""
        if not (form["suffix"] in MEGA_SUFFIXES and form["form_label"].startswith("Mega ")):
            continue
        want_tag = tags.get(form["suffix"], "")
        species = re.sub(r"[^a-z]", "", form["name"].lower())
        best = None
        for name in names:
            flat = re.sub(r"[^a-zA-Z]", "", name).lower()
            if "ite" not in flat:
                continue
            # "Dragonite" -> "Dragoninite", "Mawile" -> "Mawilite": the stem is
            # a prefix of the species, so compare on the first few letters.
            stem = min(len(species), 5)
            if not flat.startswith(species[:stem]):
                continue
            has_tag = name.rstrip().endswith((" X", " Y", " Z"))
            tag = name.rstrip()[-1] if has_tag else ""
            if tag != want_tag:
                continue
            if best is None or len(name) < len(best):
                best = name
        if best:
            form["stone"] = best
            matched += 1
        else:
            unmatched.append(form["form_label"])
    print("    stones: %d Megas linked, %d using the generic entry" % (matched, len(unmatched)))
    if unmatched:
        print("      " + ", ".join(unmatched[:12]) + ("…" if len(unmatched) > 12 else ""))


def audit_abilities(abilities):
    """Catch descriptions that have run into a neighbouring ability.

    Serebii puts every ability for a form in one cell, so a parser that gets the
    boundaries wrong produces text that reads fine until you notice Armor Tail
    explaining Sap Sipper. The signature is another ability's name immediately
    followed by a colon, or a description left dangling on punctuation.
    """
    names = sorted(abilities, key=len, reverse=True)
    problems = []
    for name, entry in abilities.items():
        desc = entry["desc"]
        if not desc:
            problems.append("%s: no description" % name)
            continue
        if desc.rstrip().endswith((":", "-", ">")):
            problems.append("%s: description ends on punctuation" % name)
        for other in names:
            if other != name and other + " :" in desc:
                problems.append("%s: runs into %s" % (name, other))
                break
    if problems:
        print("    abilities: %d suspect description(s)" % len(problems))
        for problem in problems[:10]:
            print("      - " + problem)
    else:
        print("    abilities: %d descriptions, all cleanly bounded" % len(abilities))


def audit_overlay(overlay, roster, moves, items):
    """Check every hand-written reference in overlay.json against the scraped data.

    The curated usage table is the one part of the dataset written from reading
    rather than scraping, so it is the one part that can quietly describe
    Pokémon, moves or items this game does not have. It has: an early draft
    listed Amoonguss, Pelipper and Ursaluna, none of which are in Champions'
    205-species roster, and gave Sinistcha a Spore that exists in no Champions
    learnset. Fail loudly instead.
    """
    labels = {f["form_label"] for f in roster}
    names = {f["name"] for f in roster}
    by_label = {f["form_label"]: f for f in roster}
    move_names = {m["name"] for m in moves.values()}
    move_ids = {m["name"]: m["id"] for m in moves.values()}
    item_names = {i["name"] for i in items}

    problems = []
    for entry in overlay["usage"]:
        name = entry["name"]
        alt = name.replace("-F", " (Female)").replace("-M", " (Male)")
        known = name in labels or name in names or alt in labels
        if not known:
            problems.append("%s: no such Pokémon in the roster" % name)
            continue
        form = by_label.get(name) or by_label.get(alt)
        for move in entry["key_moves"]:
            if move not in move_names:
                problems.append("%s: move '%s' does not exist in Champions" % (name, move))
            elif form and move_ids[move] not in form["moves"]:
                problems.append("%s: does not learn '%s'" % (name, move))
        for item in entry["common_items"]:
            if item not in item_names:
                problems.append("%s: item '%s' is not in the itemdex" % (name, item))

    if not problems:
        print("    overlay: every usage reference resolves")
        return
    # Pending M-C content is expected to dangle; anything else is a mistake.
    pending = set(overlay["regulation"]["new_pokemon"]) | set(overlay["regulation"]["new_megas"])
    hard = [p for p in problems if p.split(":")[0] not in pending]
    print("    overlay: %d unresolved reference(s)%s"
          % (len(problems), " (%d not explained by pending M-C content)" % len(hard) if hard else ""))
    for problem in problems[:20]:
        print("      - " + problem)


if __name__ == "__main__":
    main()
