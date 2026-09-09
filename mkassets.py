#!/usr/bin/env python3
"""Copy sprites, type icons and item icons out of the PKHeX.Mac checkout.

PKHeX already carries clean, consistently-sized art for everything this app
needs, so there is no reason to redraw it or to keep Serebii's 40px dex icons:

    hires/<dex>.png                 512x512 HOME renders, base forms
    hires/forms/<id>.png            512x512 renders for alternate forms
    hires/forms.json                PokeAPI slug -> form id
    types/square/type_icon_NN.png   18 type badges, 60x60
    img/items/bitem_N.png           item sprites, indexed by item ID

Two different lookups are involved. Item IDs come from PKHeX's own name table,
where line 1 is "None" (ID 0), so an item's ID is its line number minus one —
Rocky Helmet on line 541 is ID 540 and draws from bitem_540.png. Sprites go
through forms.json instead, which is keyed by PokeAPI slug: "garchomp-mega-z"
resolves to 10309, and thus to hires/forms/10309.png.

Renders are downscaled to 256px on the way in. At 512 the sprite set alone is
over 300 MB, and nothing in the UI draws one larger than 88pt.

The results are committed, so this only needs re-running when the roster grows.
If the PKHeX checkout is missing, the app still builds — type chips fall back to
the palette in Types.swift and sprites to a placeholder glyph.

    ./mkassets.py [path-to-PkHex-Mac]
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PKHEX = os.path.join(os.path.dirname(HERE), "PkHex Mac")

# PKHeX's internal type order, verified against the sprites themselves.
TYPES = ["Normal", "Fighting", "Flying", "Poison", "Ground", "Rock", "Bug",
         "Ghost", "Steel", "Fire", "Water", "Grass", "Electric", "Psychic",
         "Ice", "Dragon", "Dark", "Fairy"]

SPRITE_PX = 256

# Our icon suffix -> the PokeAPI slug fragment forms.json is keyed by. Keyed
# "species:suffix" where the letter is reused across species: "-a" is Alolan on
# Ninetales but a Paldean breed on Tauros, "-m" is Mow on Rotom and Midnight on
# Lycanroc. Mega suffixes are handled separately since they apply to any species.
FORM_SLUGS = {
    "aegislash:b": "blade",
    "arcanine:h": "hisui", "avalugg:h": "hisui", "decidueye:h": "hisui",
    "goodra:h": "hisui", "samurott:h": "hisui", "typhlosion:h": "hisui",
    "zoroark:h": "hisui",
    "floette:e": "eternal",
    "gourgeist:s": "small", "gourgeist:l": "large", "gourgeist:h": "super",
    "indeedee:f": "female", "meowstic:f": "female",
    "lycanroc:d": "dusk", "lycanroc:m": "midnight",
    "ninetales:a": "alola", "raichu:a": "alola",
    "rotom:f": "wash", "rotom:h": "heat", "rotom:m": "mow", "rotom:s": "fan",
    "slowbro:g": "galar", "slowking:g": "galar", "stunfisk:g": "galar",
    "tauros:a": "paldea-aqua-breed", "tauros:b": "paldea-blaze-breed",
    "tauros:p": "paldea-combat-breed",
    "toxtricity:l": "low-key",
}

MEGA_SLUGS = {"m": "mega", "mx": "mega-x", "my": "mega-y", "mz": "mega-z"}

# Megas whose slug carries a qualifier the species name alone does not imply.
# Meowstic's render is filed under the male form it evolves from.
MEGA_SLUG_OVERRIDES = {"meowstic:m": "meowstic-male-mega"}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PKHEX
    if not os.path.isdir(root):
        print("PKHeX checkout not found at %s" % root)
        print("Pass its path as an argument. Skipping icon import.")
        return 1

    types_src = os.path.join(
        root, "upstream/PKHeX/PKHeX.Drawing.Misc/Resources/img/types/square")
    items_src = os.path.join(root, "PKHeX.Mac/Assets/img/items")
    names_src = os.path.join(
        root, "upstream/PKHeX/PKHeX.Core/Resources/text/items/text_Items_en.txt")

    for path in (types_src, items_src, names_src):
        if not os.path.exists(path):
            print("missing: %s" % path)
            return 1

    types_dst = os.path.join(HERE, "data", "types")
    items_dst = os.path.join(HERE, "data", "items")
    os.makedirs(types_dst, exist_ok=True)
    os.makedirs(items_dst, exist_ok=True)

    for index, name in enumerate(TYPES):
        src = os.path.join(types_src, "type_icon_%02d.png" % index)
        shutil.copyfile(src, os.path.join(types_dst, "%s.png" % name))
    print("==> %d type icons" % len(TYPES))

    copy_sprites(root)

    with open(names_src, encoding="utf-8") as fh:
        lines = [ln.strip() for ln in fh]
    ids = {}
    for line_no, label in enumerate(lines, start=1):
        if label:
            ids.setdefault(norm(label), line_no - 1)

    with open(os.path.join(HERE, "data", "champions.json"), encoding="utf-8") as fh:
        items = json.load(fh)["items"]

    # The bitem_ sprite set stops at ID 1606, which predates the Gen 9 items
    # (Booster Energy, Clear Amulet, Covert Cloak, Loaded Dice...). The
    # items-artwork set runs to 2684 and is drawn in a compatible style, so fall
    # back to it rather than shipping those items iconless.
    art_src = os.path.join(root, "PKHeX.Mac/Assets/img/items-artwork")

    copied, from_art, missing = 0, 0, []
    for item in items:
        item_id = ids.get(norm(item["name"]))
        if item_id is None:
            missing.append(item["name"])
            continue
        dst = os.path.join(items_dst, "%s.png" % item["slug"])
        src = os.path.join(items_src, "bitem_%d.png" % item_id)
        if os.path.exists(src):
            shutil.copyfile(src, dst)
            copied += 1
            continue
        alt = os.path.join(art_src, "aitem_%d.png" % item_id)
        if os.path.exists(alt):
            shutil.copyfile(alt, dst)
            copied += 1
            from_art += 1
            continue
        missing.append(item["name"])
    print("==> %d item icons (%d from the artwork set)" % (copied, from_art))
    if missing:
        print("    no icon for %d: %s" % (len(missing), ", ".join(missing[:12])))
    return 0


def copy_sprites(root):
    """Replace the dex icons with PKHeX's 512px HOME renders, downscaled.

    Base forms are named by dex number; everything else goes through forms.json,
    which is keyed by PokeAPI slug. A form with no dedicated render falls back to
    its base species rather than to nothing — a Gourgeist size difference is not
    worth an empty frame.
    """
    hires = os.path.join(root, "PKHeX.Mac/Assets/hires")
    forms_dir = os.path.join(hires, "forms")
    index_path = os.path.join(hires, "forms.json")
    if not os.path.isdir(hires):
        print("==> no hires sprites at %s, keeping existing" % hires)
        return

    form_ids = {}
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as fh:
            form_ids = json.load(fh)

    with open(os.path.join(HERE, "data", "champions.json"), encoding="utf-8") as fh:
        forms = json.load(fh)["forms"]

    dst = os.path.join(HERE, "data", "sprites")
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst, exist_ok=True)

    exact, fellback, missing = 0, [], []
    for form in forms:
        species = form["species"].replace("'", "").replace(".", "").replace(" ", "-")
        suffix = form["suffix"]
        slug = None
        key = "%s:%s" % (form["species"], suffix)
        if suffix in MEGA_SLUGS and form["form_label"].startswith("Mega"):
            slug = MEGA_SLUG_OVERRIDES.get(key, "%s-%s" % (species, MEGA_SLUGS[suffix]))
        elif suffix:
            fragment = FORM_SLUGS.get(key)
            if fragment:
                slug = "%s-%s" % (species, fragment)

        src = None
        if slug and slug in form_ids:
            candidate = os.path.join(forms_dir, "%d.png" % form_ids[slug])
            if os.path.exists(candidate):
                src = candidate
        if src is None:
            candidate = os.path.join(hires, "%d.png" % form["dex"])
            if os.path.exists(candidate):
                src = candidate
                if suffix:
                    fellback.append(form["form_label"])
        if src is None:
            missing.append(form["form_label"])
            continue

        out = os.path.join(dst, "%s.png" % form["icon"])
        # sips rather than Pillow: it ships with macOS, so a clean checkout needs
        # nothing installed to regenerate the sprite set.
        subprocess.run(["sips", "-Z", str(SPRITE_PX), src, "--out", out],
                       capture_output=True, check=False)
        if os.path.exists(out):
            exact += 1

    print("==> %d sprites at %dpx" % (exact, SPRITE_PX))
    if fellback:
        print("    %d alternate forms using the base render: %s"
              % (len(fellback), ", ".join(sorted(set(fellback))[:8])))
    if missing:
        print("    no render for %d: %s" % (len(missing), ", ".join(missing[:8])))


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


if __name__ == "__main__":
    sys.exit(main())
