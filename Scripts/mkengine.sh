#!/bin/zsh
#  Showdown's own battle engine, bundled to one file this app can run.
#
#  The sim is Node's: it reads its data off disk with `require(path)` built at
#  runtime, which nothing can resolve ahead of time. So the data is gathered
#  into a registry first (Scripts/engine/registry.js), the three Node modules
#  the sim reaches for are written out by hand (prelude.js), and the bundle is
#  stitched prelude + registry + sim. What comes out runs in JavaScriptCore,
#  which every Mac already has, so nothing extra ships and nothing extra is
#  signed.
#
#  Tracked against master rather than a release: the tags lag, and the format
#  this app plays -- VGC 2026 Reg M-C -- reached master before any tag.
#
#      ./Scripts/mkengine.sh            build at the pinned commit
#      ./Scripts/mkengine.sh --latest   move the pin to master's head first
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/.cache/showdown"
PIN="$ROOT/Scripts/engine/pinned.txt"

if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning pokemon-showdown"
  git clone --quiet --filter=blob:none https://github.com/smogon/pokemon-showdown.git "$SRC"
fi

cd "$SRC"
git fetch --quiet origin master
if [ "$1" = "--latest" ]; then
  git rev-parse origin/master > "$PIN"
  echo "==> pin moved to $(cat $PIN)"
fi
COMMIT=$(cat "$PIN")
git checkout --quiet "$COMMIT"
echo "==> showdown at $(git log -1 --format='%h %ad %s' --date=short)"

npm install --silent --no-audit --no-fund
node build > /dev/null

# The server's half of the project, cut out of the build tree. None of it is
# reached by a battle -- an HTTP client, a MySQL driver, a process manager, a
# REPL, a crash reporter -- but `lib/sql` asks for its extensions with
# `require("../" + name)`, and a bundler reads that as "every file under the
# project", source maps and all. Emptying them is the whole fix, and `dist`
# is generated, so nothing of the checkout is touched.
for f in lib/sql.js lib/net.js lib/repl.js lib/process-manager.js lib/crashlogger.js; do
  [ -f "$SRC/dist/$f" ] && echo "module.exports = {};" > "$SRC/dist/$f"
done
echo "==> sim built"

cp "$ROOT/Scripts/engine/registry.js" "$ROOT/Scripts/engine/api.js" "$SRC/"
BUNDLE="$ROOT/data/showdown-engine.js"
ESB="$SRC/node_modules/.bin/esbuild"

# Node's own modules, written out or emptied. `browser` rather than `neutral`
# so that the one real dependency -- ts-chacha20, the sim's stream cipher --
# still resolves out of node_modules.
ALIASES=(
  --alias:fs="$ROOT/Scripts/engine/shim-fs.js"
  --alias:node:fs="$ROOT/Scripts/engine/shim-fs.js"
  --alias:path="$ROOT/Scripts/engine/shim-path.js"
  --alias:node:path="$ROOT/Scripts/engine/shim-path.js"
  --alias:child_process="$ROOT/Scripts/engine/shim-child_process.js"
  --alias:util="$ROOT/Scripts/engine/shim-util.js"
  --alias:node:util="$ROOT/Scripts/engine/shim-util.js"
)
for b in net http https stream events crypto os zlib url tls dns worker_threads \
         cluster dgram assert buffer querystring string_decoder timers readline tty v8 \
         vm perf_hooks async_hooks constants module process punycode repl sqlite \
         inspector diagnostics_channel; do
  ALIASES+=(--alias:$b="$ROOT/Scripts/engine/shim-empty.js")
  ALIASES+=(--alias:node:$b="$ROOT/Scripts/engine/shim-empty.js")
done

# `--keep-names` is not optional. Showdown serialises a battle by writing
# down each object's class name and rebuilds it by looking that name up, so a
# minifier that renames the classes leaves a restored battle as plain objects
# with none of their methods -- which is a search that cannot take a position
# back, reported as `getMoveRequestData is not a function`.

# The data first, so the sim's runtime `require` has somewhere to look.
"$ESB" "$SRC/registry.js" --bundle --format=iife --platform=browser \
  "${ALIASES[@]}" --minify --keep-names --log-level=error --outfile=/tmp/ps-registry.js

# Then the sim. `require` is already defined by the prelude, which is exactly
# what esbuild's own fallback looks for before giving up on a dynamic require.
"$ESB" "$SRC/api.js" --bundle --format=iife --platform=browser \
  "${ALIASES[@]}" \
  --banner:js='var require = function (p) { return globalThis.__psResolve(p); };' \
  --minify --keep-names --log-level=error --outfile=/tmp/ps-sim.js

# Every protocol tag the simulator can emit, read out of its own source.
# The reader is checked against this: a tag that is neither read nor named as
# chrome fails a test, which is how Mega Evolution stopped being dropped
# silently and how the next one will.
python3 - "$SRC" > "$ROOT/data/showdown-protocol.txt" <<'TAGS'
import re, sys, glob, os
root = sys.argv[1]
pat = re.compile(r"\.add(?:Move|Split)?\(\s*[`'\"](-?[a-zA-Z0-9]+)[`'\"]")
tags = set()
for pattern in ('sim/*.ts', 'data/*.ts', 'data/mods/champions/*.ts'):
    for path in glob.glob(os.path.join(root, pattern)):
        with open(path, encoding='utf-8') as fh:
            tags.update(m.group(1) for m in pat.finditer(fh.read()))
for tag in sorted(tags):
    print(tag)
TAGS
echo "==> $(wc -l < "$ROOT/data/showdown-protocol.txt" | tr -d ' ') protocol tags written"

# And the sentences the client prints for them. The protocol's tags are not
# English -- "-start|move: Yawn" glued to a name reads "Salamence is Yawn" --
# and the English is in the sim's own text tables, which ship with it.
node "$ROOT/Scripts/mktext.js" "$SRC" "$ROOT/data/showdown-text.json"

cat "$ROOT/Scripts/engine/prelude.js" /tmp/ps-registry.js /tmp/ps-sim.js > "$BUNDLE"
echo "==> wrote $BUNDLE ($(du -h "$BUNDLE" | cut -f1)), showdown $COMMIT"
