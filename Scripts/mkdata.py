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
    ./mkdata.py --delta        # pick up a new release: re-read the indexes,
                               # then fetch only what is new or changed
    ./mkdata.py --full         # re-fetch everything (same as --refresh)
    ./mkdata.py --only-roster  # roster + abilities, skip the slow move pass

Champions will keep adding Pokemon, Megas, moves and items. A plain run reuses
every cached page, so it cannot see a release at all; a full run re-fetches
about fourteen hundred pages to find the dozen that changed. `--delta` is the
one to reach for: it re-reads the three index pages, works out what is new
against the dataset already on disk, and fetches detail pages only for those.
Either way the run writes data/changes.json saying what moved, so a release's
additions are a list rather than a diff of a 1.3 MB file.
"""

import html
import json
import os
import re
import unicodedata
import subprocess
import sys
import time

BASE = "https://www.serebii.net"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the repository root
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

overlay_usage_cache = []

REFRESH = "--refresh" in sys.argv or "--full" in sys.argv
ONLY_ROSTER = "--only-roster" in sys.argv
DELTA = "--delta" in sys.argv
CHANGES = os.path.join(HERE, "data", "changes.json")

# Pages to re-fetch even though they are cached. A delta run puts the three
# index pages in here first, then adds the detail pages for whatever the
# indexes say is new.
FORCE = set()


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
    if os.path.exists(dest) and not REFRESH and path not in FORCE:
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


def with_eternal_floette(roster):
    """Add Eternal Flower Floette, which Serebii's Champions listings leave out.

    It is the Floette that Mega Evolves — the only one that can — and the one
    every tournament list means by "Floette". Its stats are the Eternal
    Flower's (74/65/67/125/128/92), its typing, abilities and learnset are
    Floette's, and its icon is 670-e, which both Serebii and the PKHeX render
    set know. Without this row the app showed a plain Floette holding a stone
    it could not use.
    """
    base = next((f for f in roster if f["icon"] == "670"), None)
    if base is None or any(f["icon"] == "670-e" for f in roster):
        return roster
    eternal = dict(base)
    eternal.update({
        "icon": "670-e",
        "suffix": "e",
        "stats": [74, 65, 67, 125, 128, 92],
    })
    return sorted(roster + [eternal], key=lambda f: (f["dex"], f["suffix"]))


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


def parse_weight(section):
    """The form's weight in kilograms.

    Low Kick and Grass Knot work their power out from the target's weight, and
    Heavy Slam and Heat Crash from the ratio of the two, so this is a damage
    input and not a piece of flavour. Serebii prints pounds and kilograms in
    one cell: "220.5lbs<br /> 100kg". Each form carries its own -- Mega
    Venusaur is 155.5kg to Venusaur's 100kg -- which is why it is read per
    section rather than per page.
    """
    m = re.search(r"([\d.]+)\s*kg", section)
    return float(m.group(1)) if m else 0.0


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
            "weight": parse_weight(section),
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


# Values Serebii's Champions pages print wrong, with the evidence for saying
# so. Kept deliberately short: the dex is the authority, and every entry here
# is a claim that one particular cell contradicts the rest of the same dex.
MOVE_CORRECTIONS = {
    # Serebii's Champions page prints Quick Guard at +1. Every other priority
    # on the same pages matches the main series exactly -- Protect +4, its own
    # sibling Wide Guard +3, Fake Out +3, Trick Room -7 -- and at +1 the move
    # loses to the Fake Out it exists to stop, which is not a move anyone would
    # print. Read as a typo for the main series' +3.
    "quickguard": {"priority": 3},
}


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
        **MOVE_CORRECTIONS.get(slug, {}),
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

def previous():
    """The dataset already on disk, or None on a first run."""
    if not os.path.exists(OUT):
        return None
    try:
        with open(OUT, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def plan_delta(before):
    """Work out what a new release added, and queue only those pages.

    The three index pages are re-read every time -- they are the only way to
    learn that something exists at all -- and then detail pages are fetched for
    whatever they name that the dataset on disk has never heard of. A release
    that adds twelve Pokemon costs twelve species pages instead of fourteen
    hundred.

    A species already in the dataset is re-read too when the roster now lists a
    form of it that was not there before, which is how a new Mega arrives: the
    species page is cached, and the Mega lives on it.
    """
    if before is None:
        print("==> delta: nothing on disk to compare against, doing a full pass")
        FORCE.clear()
        return
    # The indexes first, because nothing else can be known without them.
    for type_name in (t.lower() for t in TYPE_ORDER):
        FORCE.add("/pokedex-champions/%s.shtml" % type_name)
    FORCE.add("/attackdex-champions/")
    FORCE.add("/itemdex/list/holditem.shtml")
    FORCE.add("/itemdex/list/megastone.shtml")

    roster = with_eternal_floette(parse_roster())
    known_forms = {f["icon"] for f in before.get("forms", [])}
    known_species = {f["species"] for f in before.get("forms", [])}
    new_forms = [f for f in roster if f["icon"] not in known_forms]
    # Any species carrying a new form needs its page re-read, new or not.
    for form in new_forms:
        FORCE.add("/pokedex-champions/%s/" % form["species"])
    fresh_species = sorted({f["species"] for f in new_forms} - known_species)

    known_moves = set(before.get("moves", {}))
    new_moves = sorted(set(parse_move_index()) - known_moves) if not ONLY_ROSTER else []
    for slug in new_moves:
        FORCE.add("/attackdex-champions/%s.shtml" % slug)

    known_items = {i["slug"] for i in before.get("items", [])}
    new_items = sorted(set(parse_item_index()) - known_items) if not ONLY_ROSTER else []
    for slug in new_items:
        FORCE.add("/itemdex/%s.shtml" % slug)

    print("==> delta against the dataset on disk")
    print("    %d new forms (%d new species), %d new moves, %d new items"
          % (len(new_forms), len(fresh_species), len(new_moves), len(new_items)))
    # Names, not labels: parse_roster has not built the display label yet, and
    # "%s" % a or b binds the format tighter than the or, so this printed None.
    for form in new_forms[:20]:
        print("      form  %s (%s)" % (form["name"], form["icon"]))
    for slug in new_moves[:20]:
        print("      move  %s" % slug)
    for slug in new_items[:20]:
        print("      item  %s" % slug)
    if not new_forms and not new_moves and not new_items:
        print("      nothing new; the indexes match what is already here")


def write_changes(before, roster, moves, items):
    """Say what moved, as a list rather than a diff of a 1.3 MB file.

    Written on every run, not just a delta one, so the answer to "what did this
    release add" does not depend on having remembered to pass a flag.
    """
    def named(rows, key):
        return {r[key] for r in rows}
    was_forms = named(before.get("forms", []), "icon") if before else set()
    was_labels = {f.get("form_label") or f["name"] for f in (before or {}).get("forms", [])}
    was_moves = set(before.get("moves", {})) if before else set()
    was_items = named(before.get("items", []), "slug") if before else set()

    added_forms = [f.get("form_label") or f["name"] for f in roster if f["icon"] not in was_forms]
    changes = {
        "generated": time.strftime("%Y-%m-%d"),
        "against": (before or {}).get("generated", "nothing"),
        "forms_added": sorted(added_forms),
        "megas_added": sorted(n for n in added_forms if n.startswith("Mega ")),
        "moves_added": sorted(moves[s]["name"] for s in set(moves) - was_moves),
        "items_added": sorted(i["name"] for i in items if i["slug"] not in was_items),
        "forms_removed": sorted(was_labels - {f.get("form_label") or f["name"] for f in roster}),
    }
    with open(CHANGES, "w", encoding="utf-8") as fh:
        json.dump(changes, fh, indent=1, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    total = sum(len(changes[k]) for k in
                ("forms_added", "moves_added", "items_added", "forms_removed"))
    if total:
        print("==> changes against %s: %d forms, %d moves, %d items added, %d forms gone"
              % (changes["against"], len(changes["forms_added"]),
                 len(changes["moves_added"]), len(changes["items_added"]),
                 len(changes["forms_removed"])))
        for name in changes["forms_added"][:20]:
            print("      + %s" % name)
    else:
        print("==> no change against %s" % changes["against"])
    return changes


def main():
    before = previous()
    if DELTA:
        plan_delta(before)
    print("==> roster")
    roster = parse_roster()
    roster = with_eternal_floette(roster)
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
                row["weight"] = (card or {}).get("weight", 0.0)
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

    # Real ladder usage, if mkusage.py has been run.
    global overlay_usage_cache
    overlay_usage_cache = overlay["usage"]
    live = load_live_usage(roster, moves, items)
    if live:
        overlay["usage"] = live

    # Real tournament results, appended to the hand-written archetypes.
    usage_by_name = {e["name"]: e for e in overlay["usage"]}
    tournaments = load_tournaments(roster, usage_by_name, moves, items)
    harvest_items(tournaments, items, roster)
    if tournaments:
        overlay["meta_teams"] = [t for t in overlay["meta_teams"]
                                 if not t.get("tournament")] + tournaments

    assign_stones(roster, items)
    name_unpublished_stones(roster, items)
    mark_attested(items, overlay["meta_teams"], overlay["usage"], roster)
    apply_showdown(moves)
    split_regional_forms(roster)
    apply_brings(roster)

    # The Champions roster says what it is, so nothing has to infer it from
    # the absence of a flag.
    showdown = {}
    if os.path.exists(SHOWDOWN):
        with open(SHOWDOWN, encoding="utf-8") as fh:
            showdown = json.load(fh)
    else:
        print("    ! data/showdown.json missing — no wider roster and no tiers")
    for form in roster:
        ident = (form.get("showdown") or form["form_label"]).lower()
        ident = "".join(c for c in ident if c.isalnum())
        form["legal"] = True
        form["source"] = "champions"
        form["tier"] = showdown.get("forms", {}).get(ident, {}).get("tier")
    wider = build_wider(roster, showdown, moves)

    out = {
        "regulation": overlay["regulation"],
        "rules": overlay["rules"],
        "items": items,
        "usage": overlay["usage"],
        "meta_teams": overlay["meta_teams"],
        "predictions": overlay["predictions"],
        "notes": overlay["notes"],
        "forms": roster,
        "wider": wider,
        "moves": moves,
        "abilities": abilities,
        "provenance": dict(PROVENANCE, forms=len(roster),
                           wider_forms=len(wider),
                           wider_source="pokemon-showdown data/pokedex.ts and data/learnsets.ts; "
                                        "legality from data/mods/champions/formats-data.ts",
                           forms_weighed=sum(1 for f in roster if f.get("weight"))),
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
    print("    and %d more the main series has and this game has not" % len(wider))

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

    write_changes(before, roster, moves, items)
    audit_overlay(overlay, roster, moves, items)


SHOWDOWN = os.path.join(HERE, "data", "showdown.json")
BRINGS = os.path.join(HERE, "data", "brings.json")

# Where each part of the dataset came from, written into it so the app can say
# so. Filled in as the merge runs; empty when the reference table is absent.
PROVENANCE = {}


def showdown_form_keys(label, species):
    """Every key the reference table might file a Champions form under.

    Serebii writes "Alolan Ninetales" and "Mega Charizard X"; the reference
    table writes "Ninetales-Alola" and "Charizard-Mega-X". Neither is wrong,
    they just have to be introduced.
    """
    def key(text):
        return re.sub(r"[^a-z0-9]", "", text.lower())

    out = []
    mega = re.match(r"^Mega (.+?)(?: ([XYZ]))?$", label)
    if mega:
        base = key(mega.group(1))
        if mega.group(2):
            out.append(base + "mega" + mega.group(2).lower())
        out.append(base + "mega")
    for word, tag in (("Alolan", "alola"), ("Galarian", "galar"),
                      ("Hisuian", "hisui"), ("Paldean", "paldea")):
        if label.startswith(word + " "):
            rest = label[len(word) + 1:]
            variant = re.search(r"\((.+?)\)", rest)
            base = key(re.sub(r"\s*\(.*\)", "", rest))
            if variant:
                out.append(base + tag + key(variant.group(1)))
            out.append(base + tag)
    bracket = re.search(r"\((.+?)\)$", label)
    if bracket:
        base = key(re.sub(r"\s*\(.*\)$", "", label))
        out.append(base + key(bracket.group(1)))
        # "Indeedee (Female)" is filed as "indeedeef".
        out.append(base + key(bracket.group(1))[0])
    out.append(key(label))
    return out


def split_regional_forms(roster):
    """Give each form only the abilities and the weight that are its own.

    Serebii's Champions pages file a regional form on its base form's card, so
    both come back carrying the union: Ninetales and Alolan Ninetales each with
    Flash Fire, Drought, Snow Cloak and Snow Warning, and nothing to say which
    two are whose. The builder would let a plain Ninetales bring Snow Warning.

    The reference table keeps them apart, so it is used to split the list back
    up — but only ever to *narrow* it. An ability the Champions page does not
    list is never added, because Champions decides what is legal here.

    Weight gets the same treatment, and needed it: Alolan Raichu was carrying
    plain Raichu's thirty kilograms rather than its own twenty-one, and Low
    Kick, Grass Knot, Heavy Slam and Heat Crash all read that number.
    """
    if not os.path.exists(SHOWDOWN):
        return
    with open(SHOWDOWN, encoding="utf-8") as fh:
        forms = json.load(fh).get("forms", {})
    if not forms:
        return

    narrowed = reweighed = 0
    for form in roster:
        ref = None
        for key in showdown_form_keys(form["form_label"], form["species"]):
            if key in forms:
                ref = forms[key]
                break
        if ref is None:
            continue
        # The name Showdown files it under, which is also how its sprites are
        # named: the battle screen's pixel style fetches them by it.
        form["showdown"] = ref["name"]
        ours = [a["name"] for a in form.get("abilities", [])]
        theirs = [a for a in ref["abilities"] if a in ours]
        # Only when it actually splits something, and never down to nothing:
        # a Champions-only form the table has never seen keeps what it has.
        if theirs and len(theirs) < len(ours):
            keep = set(theirs)
            form["abilities"] = [a for a in form["abilities"] if a["name"] in keep]
            narrowed += 1
        if ref["weight"] and abs((form.get("weight") or 0) - ref["weight"]) > 0.05:
            form["weight"] = ref["weight"]
            reweighed += 1
    PROVENANCE["forms_split"] = narrowed
    PROVENANCE["weights_corrected"] = reweighed
    print("==> forms: %d had a shared ability list split apart, %d weights corrected"
          % (narrowed, reweighed))


def champions_odds(move, secondaries):
    """Showdown's structure, Serebii's numbers.

    Champions is not the main series and is free to rebalance. Serebii's
    Champions Attackdex is the authority on what a move does *here*, and it
    already writes the odds into the sentence: "Has a 20% chance of making the
    target flinch." What it does not do is say clearly which effect those odds
    belong to, or that a move has two of them, which is the part Showdown is
    read for.

    So the shape comes from Showdown and the percentages from Serebii, matched
    in the order both write them. Iron Head is the case that matters today: 20%
    here, 30% in the main series. Taking Showdown's number would have quietly
    replaced a Champions rebalance with a main-series value.
    """
    if not secondaries:
        return secondaries
    stated = [int(n) for n in re.findall(r"(\d+)% chance", move.get("effect", ""))]
    if len(stated) != len(secondaries):
        return secondaries
    out = []
    for odds, effect in zip(stated, secondaries):
        entry = dict(effect)
        entry["chance"] = odds
        out.append(entry)
    return out


def apply_brings(roster):
    """Attach how often each form is actually brought, and how often it leads.

    Measured from real ladder games by Scripts/mkreplays.py. The engine used to
    guess an opponent's back two purely by scoring every possible four the way
    its own matchup grid scores it — a theory of how somebody chooses, never
    checked against somebody choosing. Held against a thousand real games it
    named the right *pair* no better than chance.

    This is the evidence it was missing. Four of six is 67%; a Pokemon brought
    83% of the time it is on a team, or 37%, is telling you something the grid
    cannot work out.
    """
    if not os.path.exists(BRINGS):
        return
    with open(BRINGS, encoding="utf-8") as fh:
        rates = json.load(fh).get("rates", {})
    if not rates:
        return

    def key(text):
        return re.sub(r"[^a-z0-9]", "", text.lower())

    by_key = {key(name): row for name, row in rates.items()}
    matched = 0
    for form in roster:
        # Showdown writes "Indeedee-F" where the dex writes "Indeedee (Female)".
        row = by_key.get(key(form["form_label"])) or by_key.get(key(form["name"]))
        if row is None:
            continue
        form["brought"] = row["brought"]
        form["led"] = row["led"]
        matched += 1
    print("==> brings: %d forms carry a measured bring rate" % matched)


def apply_showdown(moves):
    """Take each move's secondary effects and flags from Showdown's table.

    Serebii writes what a move does in English, and the only way to get it out
    is to guess at the sentence. That guessing was wrong for ninety-one of the
    five hundred and ten legal moves — Heat Wave's burn, Crunch's Defence drop,
    Iron Head's flinch, the second effect on every Fang move, which the
    sentence parser could not have represented at all because it only ever
    produced one.

    Showdown writes the same thing as data. Serebii stays the authority on what
    is *legal* here, which is the thing Showdown does not know: it has never
    heard of Mega Golisopod.

    Regenerate the table with Scripts/mkshowdown.mjs. If it is missing the
    parsed-from-English values stay in place, and the run says so, because a
    dataset that silently loses its move mechanics is worse than a loud one.
    """
    if not os.path.exists(SHOWDOWN):
        print("    ! data/showdown.json missing — move effects stay as parsed from Serebii's prose")
        print("      regenerate with: node --experimental-strip-types Scripts/mkshowdown.mjs '' data/showdown.json")
        return
    with open(SHOWDOWN, encoding="utf-8") as fh:
        loaded = json.load(fh)
    table = loaded["moves"]
    table_generated = loaded.get("generated", "")

    def key(name):
        return re.sub(r"[^a-z0-9]", "", name.lower())

    matched = carried = flagged = multihit = 0
    disagreed = {}
    rebalanced = []
    global PROVENANCE
    for move in moves.values():
        ref = table.get(key(move["name"]))
        if ref is None:
            continue
        matched += 1
        move["secondaries"] = champions_odds(move, ref["secondaries"])
        if ref.get("hits"):
            move["hits"] = ref["hits"]
            multihit += 1
        if ref.get("multiaccuracy"):
            move["multiaccuracy"] = True
        if ref.get("smartTarget"):
            move["smart_target"] = True
        if ref.get("target"):
            move["showdown_target"] = ref["target"]
        if ref.get("selfSwitch"):
            move["self_switch"] = ref["selfSwitch"]
        if move["secondaries"]:
            carried += 1
        # Flags decide which ability answers a move. Serebii publishes these
        # too and mostly agrees; where it does not, Showdown is the one that
        # has been tested against the real game for twenty years.
        # What Champions changed from the main series. Worth recording rather
        # than correcting: Serebii's Champions Attackdex is the authority for
        # this game, and a competitive player wants to know that Beak Blast
        # hits for 120 here and 100 everywhere else.
        #
        # Power 0 against power 1 is not a change; both are placeholders for a
        # move whose damage is worked out from something else.
        changed = {}
        for field, ours, mainline in (("power", move["power"], ref["power"]),
                                      ("accuracy", move["accuracy"], ref["accuracy"]),
                                      ("type", move["type"], ref["type"]),
                                      ("priority", move["priority"], ref["priority"])):
            if ours == mainline:
                continue
            if field == "power" and {ours, mainline} <= {0, 1}:
                continue
            # 0 here means "no accuracy check", which is the same thing as 100.
            if field == "accuracy" and {ours, mainline} <= {0, 100}:
                continue
            changed[field] = mainline
        if changed:
            move["mainline"] = changed
            rebalanced.append("%s (%s)" % (move["name"], ", ".join(
                "%s %s->%s" % (f, v, move[f]) for f, v in sorted(changed.items()))))
        for flag, on in ref["flags"].items():
            if move.setdefault("flags", {}).get(flag, False) != on:
                flagged += 1
                disagreed.setdefault(flag, []).append(
                    "%s %s" % ("+" if on else "-", move["name"]))
            move["flags"][flag] = on
    print("==> showdown: %d moves matched, %d carry a secondary effect, %d flags corrected,"
          " %d hit more than once" % (matched, carried, flagged, multihit))
    for flag in sorted(disagreed):
        rows = disagreed[flag]
        print("      %-12s %3d: %s" % (flag, len(rows), ", ".join(rows[:6])))
    PROVENANCE = {
        "reference": "pokemon-showdown",
        "reference_generated": table_generated,
        "moves_matched": matched,
        "moves_with_secondary": carried,
        "flags_corrected": flagged,
        "moves_rebalanced": len(rebalanced),
        "moves_multihit": multihit,
    }
    if rebalanced:
        print("    %d moves differ from the main series:" % len(rebalanced))
        for row in sorted(rebalanced)[:20]:
            print("      %s" % row)


#: Items confirmed present in Champions by someone looking at the game, with
#: nothing in the scrapes to show it. Each one is a claim by a person, which is
#: why they are listed here by hand rather than inferred.
CONFIRMED_IN_GAME = [
    "Scope Lens",       # reported in game; raises the holder's critical-hit ratio
]


def build_wider(roster, showdown, moves):
    """Everything Pokemon Champions has not got, from the main series.

    The app is about one game and is careful to be right about it: the roster,
    the stats and the learnsets all come from Serebii's *Champions* pages, and
    where Champions disagrees with the main series the difference is recorded
    rather than smoothed over. None of that is available for a Pokemon this
    game does not have, and pretending otherwise would be the one thing this
    dataset has never done.

    So these are kept apart. `forms` is Champions and nothing else -- every
    screen, every analysis, every sprite and every test that iterates it is
    unchanged. `wider` is the rest of the National Dex with main-series
    numbers, marked as such on every entry, for the sandbox mode and for the
    day the regulation rotates and something here becomes legal.

    Legality is Showdown's Champions mod rather than our own guess: it carries
    a tier for every species and says "Illegal" for the ones this game has not
    got, which is a published answer maintained by people who run the format.
    """
    have = {(f.get("showdown") or f["form_label"]).lower().replace("-", "").replace(" ", "")
            for f in roster}
    known_moves = set(moves)
    order = ["hp", "atk", "def", "spa", "spd", "spe"]
    out = []
    for ident, entry in sorted(showdown.get("forms", {}).items()):
        if ident in have:
            continue
        stats = entry.get("base_stats") or {}
        if not stats or not entry.get("types"):
            continue
        # Showdown's dex carries the Create-A-Pokemon project's fan-made
        # species, which have no National Dex number and are not Pokemon. They
        # are filed with negative numbers, which is the tidiest way to tell.
        if (entry.get("num") or 0) <= 0:
            continue
        learnable = [m for m in (showdown.get("learnsets", {}).get(ident) or [])
                     if m in known_moves]
        # Nothing it can throw is nothing to play with: it would Struggle every
        # turn. Left out rather than offered and useless.
        if not learnable:
            continue
        out.append({
            "dex": entry.get("num") or 0,
            "species": (entry.get("base_species") or entry["name"]).lower(),
            "name": entry.get("base_species") or entry["name"],
            # Prefixed so it can never collide with a Champions icon, and so
            # nothing goes looking for a bundled sprite that was never made.
            "icon": "sd-" + ident,
            "suffix": "",
            "types": entry.get("types") or [],
            "stats": [int(stats.get(k, 0)) for k in order],
            "abilities": [{"name": a, "desc": ""} for a in (entry.get("abilities") or [])],
            "weight": entry.get("weight"),
            "form_label": entry["name"],
            "moves": learnable,
            "stone": "",
            "showdown": entry["name"],
            "legal": False,
            "tier": entry.get("tier"),
            # Said on every single entry, because every screen that shows one
            # needs to be able to say it.
            "source": "main series",
        })
    print("==> wider roster: %d forms Champions has not got, from the main series"
          % len(out))
    return out


def mark_attested(items, meta_teams, usage, roster):
    """Flag which items have actually been seen in Pokemon Champions.

    Serebii has no Champions item list — its Champions hub links straight to the
    general itemdex — so what gets scraped is every hold item in the main series,
    and a good number of those are not in this game. Assault Vest is the clearest
    case: a VGC staple, and it appears in none of the registered team lists while
    Choice Scarf appears in twenty-two of them. Choice Band and Choice Specs are
    absent too, which is a plausible shape for a new game with a partial item set.

    Three things count as evidence, all of them real play:

      · an item somebody registered on a published tournament team
      · an item the measured ladder reports people holding
      · a Mega Stone belonging to a Mega that exists in this dex, since a Mega
        cannot evolve without it

    Absence is evidence, not proof: a legal but unpopular item would look the
    same as one that is not in the game. So the flag says what it actually knows
    — that nobody has been seen holding it — and the app words it that way and
    keeps the item usable in the calculator.
    """
    seen, why = set(), {}

    def note(name, reason):
        if not name:
            return
        seen.add(name)
        why.setdefault(name, reason)

    # Seen in the game itself. Serebii publishes no Champions item list, the
    # registered lists are a sample, and the ladder only reports what the
    # measured sets happened to hold -- so an item can be in the game and reach
    # none of the three. This is testimony rather than a scrape, and it is
    # written down as exactly that so the claim can be weighed for what it is.
    for name in CONFIRMED_IN_GAME:
        note(name, "confirmed in the game")

    lists = 0
    for team in meta_teams:
        # Only lists somebody actually registered. Our own written archetypes
        # are guesses, and they are exactly what put Assault Vest in here.
        if not team.get("record"):
            continue
        lists += 1
        for member in team.get("members", []):
            note(member.get("item"), "registered on a tournament team")
    for entry in usage:
        for row in (entry.get("item_usage") or []):
            note(row.get("name"), "held on the measured ladder")
        for name in (entry.get("common_items") or []):
            note(name, "held on the measured ladder")
    for form in roster:
        if form.get("stone"):
            note(form["stone"], "the stone a Mega in this dex needs")
    # The placeholder a Mega gets when Serebii has not published its stone's
    # name. The stone certainly exists — the Mega cannot evolve without one —
    # so it must not be gated; only its name is unknown.
    note("Mega Stone", "the unnamed stone a Mega in this dex needs")
    for form in roster:
        if form.get("stone", "").startswith("Mega Stone ("):
            note(form["stone"], "the unnamed stone a Mega in this dex needs")

    for item in items:
        item["attested"] = item["name"] in seen
        item["attestation"] = why.get(item["name"], "")

    missing = sorted(i["name"] for i in items if not i["attested"])
    print("==> items seen in Champions: %d of %d (from %d registered lists, "
          "the ladder, and the stones)" % (len(items) - len(missing), len(items), lists))
    notable = [n for n in missing if n in (
        "Assault Vest", "Choice Band", "Choice Specs", "Covert Cloak", "Clear Amulet",
        "Flame Orb", "Toxic Orb", "Damp Rock", "Heat Rock", "Terrain Extender",
        "Safety Goggles", "Eviolite", "Weakness Policy", "Throat Spray")]
    if notable:
        print("    main-series staples never seen here: %s" % ", ".join(notable))


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


def name_unpublished_stones(roster, items):
    """Give every Mega without a published stone a stone of its own.

    Serebii names the stone for fifty-five of the eighty-one Megas and leaves
    the rest blank. The app stood one generic "Mega Stone" in for all of them,
    which works only while a species has exactly one Mega: the builder hands
    back an item name and the rulebook has to say which Mega that triggers.
    Raichu has two and only Raichunite Y is published, so Mega Raichu X could
    be looked at and never registered -- the same for Mega Absol Z, whose
    sibling holds the Absolite.

    So each one gets a stone named after it. The name is a placeholder and says
    so; what it is not is ambiguous. The generic entry stays in the list for
    teams saved before this.
    """
    made = []
    for form in roster:
        if not (form["form_label"].startswith("Mega ")
                and form["suffix"] in ("m", "mx", "my", "mz")):
            continue
        if form.get("stone"):
            continue
        name = "Mega Stone (" + form["form_label"] + ")"
        form["stone"] = name
        if any(i["name"] == name for i in items):
            continue
        items.append({
            "name": name,
            "slug": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-"),
            "effect": "This item, when held, allows for the Pokémon to Mega Evolve in battle. Serebii has not published this stone's name; it stands in for it so the Mega can be registered and brought.",
            "short": "Mega Evolves " + form["form_label"] + ". Serebii has not published its name.",
            "fling": 0,
            "category": "Mega Stone",
            "unpublished": True,
        })
        made.append(form["form_label"])
    if made:
        print("==> stones named for %d Megas Serebii leaves blank (%s)"
              % (len(made), ", ".join(made[:6]) + ("..." if len(made) > 6 else "")))
    return made


PIKALYTICS_NAMES = {
    "Indeedee-F": "Indeedee (Female)",
    "Indeedee-M": "Indeedee",
    "Floette-Eternal": "Floette (Eternal)",
    "Basculegion-F": "Basculegion (Female)",
    "Tauros-Paldea-Aqua": "Paldean Tauros (Aqua)",
    "Tauros-Paldea-Blaze": "Paldean Tauros (Blaze)",
    "Tauros-Paldea-Combat": "Paldean Tauros (Combat)",
    "Ninetales-Alola": "Alolan Ninetales",
    "Raichu-Alola": "Alolan Raichu",
    "Arcanine-Hisui": "Hisuian Arcanine",
    "Rotom-Wash": "Rotom (Wash)",
    "Rotom-Heat": "Rotom (Heat)",
    "Maushold-Four": "Maushold (Family of Four)",
}


def pikalytics_label(slug):
    """Map a Pikalytics slug to our form label.

    Their Mega forms are suffixed ("Salamence-Mega", "Charizard-Mega-Y") where
    ours are prefixed, and their regional forms use a hyphen where ours spell
    the region out.
    """
    if slug in PIKALYTICS_NAMES:
        return PIKALYTICS_NAMES[slug]
    parts = slug.split("-")
    # "Mega" is not always the second part: tournament data carries
    # "Floette-Eternal-Mega", where the form tag comes first.
    if "Mega" in parts[1:]:
        index = parts.index("Mega", 1)
        tag = ""
        if len(parts) > index + 1 and len(parts[index + 1]) <= 2:
            tag = " " + parts[index + 1].upper()
        return "Mega %s%s" % (parts[0], tag)
    return slug.replace("-", " ")


def describe(form, entry, moves_by_name):
    """A factual one-liner for a Pokémon with no hand-written note.

    Live data replaced the curated table wholesale at first, which blanked the
    "Why it matters" text for everything. Curated prose is kept where it exists;
    this fills the rest from what the ladder actually shows rather than leaving
    an empty card.
    """
    bits = []
    top = entry.get("moves") or []
    items_used = entry.get("items") or []
    abilities = entry.get("abilities") or []
    if abilities:
        bits.append("Runs %s on %.0f%% of sets" % (abilities[0]["name"], abilities[0]["percent"]))
    if top:
        names = ", ".join(m["name"] for m in top[:3])
        bits.append("most common moves are %s" % names)
    if items_used:
        bits.append("usually holding %s (%.0f%%)"
                    % (items_used[0]["name"], items_used[0]["percent"]))
    text = "; ".join(bits)
    if text:
        text = text[0].upper() + text[1:] + "."
    rate = entry.get("winrate")
    if rate is not None:
        verdict = ("It is winning more than it loses" if rate >= 51
                   else ("It is close to even" if rate >= 49
                         else "It loses slightly more than it wins"))
        text += " %s at %.1f%% across %s recorded games." % (
            verdict, rate,
            (entry.get("wins") or 0) + (entry.get("losses") or 0))
    mates = entry.get("teammates") or []
    if mates:
        text += " Most often seen alongside %s." % ", ".join(mates[:3])
    return text.strip()


def infer_role(form, entry, moves_by_name):
    """A role label from what the Pokémon actually runs."""
    names = {m["name"] for m in (entry.get("moves") or [])}
    abilities = {a["name"] for a in (entry.get("abilities") or [])}
    if names & {"Follow Me", "Rage Powder"}:
        return "Redirection / support"
    if "Trick Room" in names:
        return "Trick Room setter"
    if "Tailwind" in names:
        return "Speed control"
    if abilities & {"Grassy Surge", "Psychic Surge", "Electric Surge", "Misty Surge"}:
        return "Terrain setter"
    if abilities & {"Drizzle", "Drought", "Sand Stream", "Snow Warning"}:
        return "Weather setter"
    if "Intimidate" in abilities or names & {"Parting Shot", "U-turn", "Volt Switch"}:
        return "Pivot / Intimidate"
    if form["stats"][1] >= form["stats"][3]:
        return "Physical attacker"
    return "Special attacker"


def clean_text(text):
    """Strip decoration from anything scraped before it enters the dataset.

    Community tournament names are full of emoji, hearts and modifier-letter
    ornament -- "\u02dc\u02cb\u02cf Pomelo Late Night Tour", "Sitrus-Series" wrapped in
    lemons. None of it belongs in a name the app prints, and it has to be
    removed everywhere the text is used rather than in one place, which is how
    it survived in the note after the title had been cleaned.
    """
    if not text:
        return ""
    out = []
    for ch in unicodedata.normalize("NFKC", text):
        category = unicodedata.category(ch)
        # So, Sk and Cn cover emoji, symbol modifiers and unassigned points.
        if category in ("So", "Sk", "Cn", "Cf"):
            continue
        # Spacing modifier letters are category Lm, so they survived the above
        # and left "\u02cb\u02cf\u02ce\u02ca Pomelo Late Night Tour" on screen. They are only
        # ever ornament in a tournament title.
        if "\u02b0" <= ch <= "\u02ff":
            continue
        # Variation selectors and zero-width joiners are invisible but still
        # occupy a slot, which is how a title ended up starting with a gap.
        if "\ufe00" <= ch <= "\ufe0f" or ch in "\u200b\u200c\u200d\u2060":
            continue
        out.append(ch)
    cleaned = "".join(out)
    cleaned = re.sub(r"[|\u00b7\u2022]+", " - ", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    return cleaned.strip(" -\u2013\u2014")


def tidy_event(name):
    """A tournament name short enough to print, cut at a word boundary.

    Deliberately conservative: earlier versions used a trailing wildcard to
    strip the regulation marker and swallowed the rest of the title with it,
    turning "r/VGC Regulation M-C Kickoff Cup" into "r/VGC". Only the marker
    itself goes, then the punctuation it leaves behind.
    """
    name = clean_text(name)
    name = re.sub(r"\b(?:Regulation|Reg)\s*(?:Set\s*)?M-?C\b", "", name, flags=re.I)
    name = re.sub(r"\$\s*\d+\s*(?:to\s*\w+|prize\s*pool)?", "", name, flags=re.I)
    # Punctuation stranded by those removals.
    name = re.sub(r"\(\s*[,;]\s*", "(", name)
    name = re.sub(r"\(\s*\)", "", name)
    name = re.sub(r"(\s*-\s*){2,}", " - ", name)
    name = re.sub(r"\s{2,}", " ", name).strip(" -")

    if len(name) > 40:
        name = name[:40].rsplit(" ", 1)[0] or name[:40]
    # Truncation can strand an open bracket or a trailing separator.
    if name.count("(") > name.count(")"):
        name = name[:name.rindex("(")]
    while name.count(")") > name.count("("):
        name = name.replace(")", "", 1)
    name = re.sub(r"[\s\-,:;(]+$", "", name)
    return name.strip() or "community tournament"


# How the events spell things against how Serebii does.
TOURNAMENT_ALIASES = {
    "Eternal Flower Floette": "Floette (Eternal)",
    "Indeedee \u2640": "Indeedee (Female)",
    "Basculegion \u2640": "Basculegion (Female)",
    "Lycanroc Dusk": "Lycanroc (Dusk)",
    "Lycanroc Midnight": "Lycanroc (Midnight)",
    "Heat Rotom": "Rotom (Heat)",
    "Wash Rotom": "Rotom (Wash)",
    "Mow Rotom": "Rotom (Mow)",
    "Fan Rotom": "Rotom (Fan)",
    "Frost Rotom": "Rotom (Frost)",
    "Hisuian Arcanine": "Hisuian Arcanine",
    "Alolan Ninetales": "Alolan Ninetales",
}


def edit_distance(a, b):
    """Levenshtein, bounded by the shorter string."""
    if abs(len(a) - len(b)) > 1:
        return 2
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def harvest_items(tournaments, items, roster):
    """Add items the events name that Serebii has not published yet.

    Team lists carry Mega Stones for forms whose stone Serebii still lists as
    blank -- thirty-one of the eighty-one Megas -- along with resist berries
    missing from the item index. They are real by virtue of somebody having
    registered and played them, and they are marked as coming from results
    rather than from the dex.
    """
    known = {i["name"] for i in items}
    by_species = {}
    for form in roster:
        if form["form_label"].startswith("Mega "):
            by_species.setdefault(form["species"], form)

    def near_duplicate(name):
        """An existing item spelled slightly differently.

        Serebii writes Floettite and the team lists write Floetite. Adding both
        gives two items for one stone and makes the item clause wrong.
        """
        squashed = re.sub(r"[^a-z]", "", name.lower())
        for existing in known:
            other = re.sub(r"[^a-z]", "", existing.lower())
            if other == squashed:
                return existing
            # One letter different, on names long enough for that to be a typo
            # rather than a different item.
            # One character apart, on names long enough for that to be a
            # spelling difference rather than a different item. A prefix test
            # was not enough: Floetite and Floettite differ in the middle.
            if len(squashed) >= 7 and edit_distance(other, squashed) <= 1:
                return existing
        return None

    added = []
    for team in tournaments:
        for member in team["members"]:
            name = member.get("item") or ""
            if not name or name in known:
                continue
            if (existing := near_duplicate(name)) is not None:
                member["item"] = existing
                continue
            known.add(name)
            stone_for = None
            for species, form in by_species.items():
                if name.lower().startswith(species.lower()[:5]):
                    stone_for = form
                    break
            described = ("Mega Evolves %s. Named in tournament team lists; Serebii "
                         "has not published it." % stone_for["species"]) if stone_for \
                        else "Named in tournament team lists but not in Serebii's index."
            entry = {
                "name": name,
                "slug": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-"),
                "effect": described,
                "short": described,
                "fling": 0,
                "category": "Mega Stone" if stone_for else "Held item",
                "from_results": True,
            }
            items.append(entry)
            added.append(name)
            if stone_for and not stone_for.get("stone"):
                stone_for["stone"] = name
    if added:
        print("==> items named only in results: %d (%s)"
              % (len(added), ", ".join(sorted(added)[:6])))
    return added


def load_tournaments(roster, usage_by_name, moves, items):
    """Fold data/tournaments.json into meta teams the app can score against.

    Written by mktournaments.py. Compositions and placements are real results;
    sets are not published with them, so each member gets the ladder's most
    common item, ability and moves. The note on every team says so.
    """
    path = os.path.join(HERE, "data", "tournaments.json")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)

    by_label = {f["form_label"]: f for f in roster}
    by_name = {f["name"]: f for f in roster if not f["suffix"]}
    move_names = {m["name"].lower(): m["name"] for m in moves.values()}
    item_names = {i["name"].lower(): i["name"] for i in items}

    def resolve(raw):
        """A team-list name to one of ours."""
        label = TOURNAMENT_ALIASES.get(raw) or pikalytics_label(raw)
        return by_label.get(label) or by_name.get(label) \
            or by_label.get(raw) or by_name.get(raw)

    out, dropped = [], []

    seen_ids = set()
    for entry in payload.get("teams", []):
        # Only this regulation. Community series run several at once.
        if re.search(r"\bM-?B\b", entry.get("event", ""), re.I):
            continue
        published = {s["name"]: s for s in entry.get("sets", [])}
        members = []
        for raw in entry["members"]:
            form = resolve(raw)
            if form is None:
                dropped.append("%s (%s)" % (raw, entry["player"]))
                continue
            given = published.get(raw)
            if given:
                # What they actually ran. Spelling is theirs, so moves and items
                # are matched without regard to case.
                real_moves = [move_names.get(m.lower(), m) for m in given["moves"]]
                item = item_names.get(given["item"].lower(), given["item"])
                ability = given["ability"] if any(
                    a["name"] == given["ability"] for a in form["abilities"]
                ) else form["abilities"][0]["name"]
                members.append({
                    "form": form["form_label"],
                    "item": item,
                    "ability": ability,
                    "moves": [m for m in real_moves if m][:4],
                    "nature": given.get("nature") or "",
                })
                continue
            measured = usage_by_name.get(form["form_label"]) or usage_by_name.get(form["name"]) or {}
            members.append({
                "form": form["form_label"],
                "item": (measured.get("common_items") or [""])[0],
                "ability": ((measured.get("ability_usage") or [{}])[0].get("name")
                            or form["abilities"][0]["name"]),
                "moves": (measured.get("key_moves") or [])[:4],
                "nature": "",
            })
        if len(members) < 4:
            continue
        placement = entry.get("placement") or ""
        # Unique per team, not per placing.
        #
        # This was "tour-<rank>", and rank is the placing *within* an event, so
        # the eighth-place team at twenty different events all shared one id.
        # 112 teams carried 17 distinct ids between them, and everything keyed
        # on the id -- the built-team cache, the opponent pool, the picker in
        # the versus screen -- silently collapsed them onto whichever arrived
        # first. Ninety-five of the published lists were never scored at all.
        slug = re.sub(r"[^a-z0-9]+", "-",
                      ("%s-%s-%d" % (entry["player"], entry["event"],
                                     entry["rank"])).lower()).strip("-")[:78]
        while slug in seen_ids:
            slug += "-x"
        seen_ids.add(slug)
        out.append({
            "id": slug,
            "name": "%s — %s" % (clean_text(entry["player"]), tidy_event(entry["event"])),
            "archetype": "Tournament result",
            "projected": False,
            "format": "doubles",
            "note": ("Real result: %s at %s%s. This is their published team list; "
                     "only the Stat Points are inferred, since nobody publishes those."
                     % (entry.get("record") or "?", tidy_event(entry["event"]),
                        ", " + clean_text(placement) if placement else "")),
            "members": members,
            "source": entry.get("source", ""),
            "tournament": True,
            "record": entry.get("record", ""),
            "placement": placement,
        })
    if dropped:
        print("    tournament members not in the dex: %s" % ", ".join(dropped[:6]))
    print("==> tournament teams: %d from %s" % (len(out), payload.get("generated")))
    return out


def load_live_usage(roster, moves, items):
    """Fold data/usage.json into the shape the app already expects.

    Written by mkusage.py from Pikalytics. Every reference is checked against the
    scraped data and dropped if it cannot be true — their ability figures are
    noisy on a format this young, and claim things like a Basculegion with Trace.
    """
    path = os.path.join(HERE, "data", "usage.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)

    by_label = {f["form_label"]: f for f in roster}
    by_name = {f["name"]: f for f in roster if not f["suffix"]}
    move_names = {m["name"]: m for m in moves.values()}
    item_names = {i["name"] for i in items}

    # Anything already written by hand is kept; the live numbers go alongside it.
    curated = {e["name"]: e for e in overlay_usage_cache}
    move_lookup = {m["name"]: m for m in moves.values()}

    out, dropped = [], []
    for entry in payload.get("entries", []):
        slug = entry["slug"]
        label = pikalytics_label(slug)
        form = by_label.get(label) or by_name.get(label) or by_name.get(slug)
        if form is None:
            dropped.append("%s: not in the roster" % slug)
            continue

        legal_moves = set(form["moves"])
        keep_moves = []
        for move in entry.get("moves", []):
            record = move_names.get(move["name"])
            if record is None or record["id"] not in legal_moves:
                dropped.append("%s: cannot learn %s" % (label, move["name"]))
                continue
            keep_moves.append(move)

        own = {a["name"] for a in form["abilities"]}
        keep_abilities = []
        for ability in entry.get("abilities", []):
            if ability["name"] not in own:
                dropped.append("%s: cannot have %s" % (label, ability["name"]))
                continue
            keep_abilities.append(ability)

        keep_items = [i for i in entry.get("items", []) if i["name"] in item_names]

        previous = curated.get(form["form_label"]) or curated.get(form["name"]) or {}
        entry_for_text = dict(entry)
        entry_for_text["moves"] = keep_moves
        entry_for_text["items"] = keep_items
        entry_for_text["abilities"] = keep_abilities

        out.append({
            "name": form["form_label"],
            "tier": tier_for(entry["usage"]),
            "usage": entry["usage"],
            "projected": False,
            "formats": previous.get("formats") or ["doubles"],
            "role": previous.get("role") or infer_role(form, entry_for_text, move_lookup),
            "common_items": [i["name"] for i in keep_items][:3],
            "key_moves": [m["name"] for m in keep_moves][:4],
            # Curated analysis wins; otherwise describe what the ladder shows.
            "why": previous.get("why") or describe(form, entry_for_text, move_lookup),
            "winrate": entry.get("winrate"),
            "wins": entry.get("wins"),
            "losses": entry.get("losses"),
            "move_usage": keep_moves,
            "item_usage": keep_items,
            "ability_usage": keep_abilities,
            "teammates": entry.get("teammates", [])[:4],
        })

    print("==> live usage: %d entries from %s (%s)"
          % (len(out), payload.get("format"), payload.get("generated")))
    if dropped:
        print("    dropped %d unverifiable reference(s):" % len(dropped))
        for item in dropped[:8]:
            print("      - " + item)
    return out


def tier_for(usage):
    if usage >= 25:
        return "S"
    if usage >= 12:
        return "A"
    if usage >= 5:
        return "B"
    return "C"


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
