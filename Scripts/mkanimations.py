#!/usr/bin/env python3
"""Translate Pokemon Showdown's move animations into a table the app can play.

    ./Scripts/mkanimations.py [path-to-client-src] > data/animations.json

The Showdown client draws every move as a short script over a handful of
primitives: a sprite flying from one pose to another (showEffect), a Pokemon
leaning toward a pose and back (anim), a pause (delay, wait), a wash of colour
over the field (backgroundEffect), the ground shaking ($bg.animate). Poses are
the attacker's or the defender's position plus an offset, in three axes -- x
left/right, y down/up, z toward the player or the opponent -- with behind(n)
and leftof(n) signed by which side the Pokemon stands on.

This reads those scripts and writes them out as data, so the app can play the
same choreography with its own drawing of each primitive. Every coordinate
comes out as a linear form over the two anchors -- a * attacker + d * defender
+ c, plus behind and leftof terms -- which is what lets a loop that steps from
one Pokemon to the other, or a midpoint, be written down rather than skipped.
Loops over a counter are unrolled; a spread move's loop over its targets is
unwrapped and the recipe marked spread, so the app plays it once per target.
Anything past that -- a recipe that reads the sprite's own size, a random
number, a switch on the move's type -- is left out and the app falls back to
the client's own fallback for that kind of move, which is also here.

The source is MIT-licensed; the drawing of each primitive is our own.
"""
import json, os, re, sys
from collections import Counter

ROOT = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else \
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.cache', 'psclient')
MOVES = os.path.join(ROOT, 'battle-animations-moves.ts')
OTHER = os.path.join(ROOT, 'battle-animations.ts')
GITHUB = 'https://raw.githubusercontent.com/smogon/pokemon-showdown-client/master/play.pokemonshowdown.com/src/'

def fetch():
    """The two client sources, into the cache. curl rather than urllib for the
    same certificate-chain reason as mkdata."""
    import subprocess
    os.makedirs(ROOT, exist_ok=True)
    for path in (MOVES, OTHER):
        subprocess.run(['curl', '-sSL', '-m', '60', GITHUB + os.path.basename(path), '-o', path], check=True)

if '--fetch' in sys.argv or not (os.path.exists(MOVES) and os.path.exists(OTHER)):
    fetch()

class Unparsed(Exception): pass


class Offscreen(Unparsed):
    """A coordinate JavaScript works out to be Infinity.

    Two moves lay their sprites out with `x: attacker.x + (50 / i)` inside a
    `for (let i = 0; ...)`, and the first turn of that loop divides by zero.
    JavaScript does not mind: it makes Infinity, adds it to a position, and
    the client dutifully sends that one sprite to a place nobody can see.
    Python minds, and the whole recipe was being thrown away over a sprite
    that was never visible in the first place.

    So this is not a parse failure. It is the parse succeeding and finding a
    step with nothing in it, and the honest translation of a sprite at
    infinity is no sprite at all.
    """

NUM = r'[+-]?\d+(?:\.\d+)?'

# ----------------------------------------------------------------- text ----

def entries(text):
    """Top-level `\tname: {` ... `\t},` blocks of a table.

    The brace can be followed by a comment -- `blizzard: { // todo: better
    blizzard anim` -- and five moves are written that way, so requiring a
    newline after it dropped them: Blizzard, Diamond Storm, Drill Run, Petal
    Dance and Sheer Cold all fell back to the generic effect for their kind.
    """
    return {m.group(1): m.group(2)
            for m in re.finditer(r'^\t([a-z0-9]+): \{[^\n]*\n(.*?)^\t\},', text, re.S | re.M)}

def section(text, header):
    i = text.index(header)
    return text[i:text.index('\n};', i)]

def alias(entry):
    """`anim: BattleOtherAnims.clawattack.anim` -- the move borrows a recipe whole."""
    m = re.search(r'\banim: Battle(Other|Move)Anims(?:\.(\w+)|\[.(\w+).\])\.anim', entry)
    return ('other' if m.group(1) == 'Other' else 'moves', m.group(2) or m.group(3)) if m else None

def anim_body(entry):
    """The body of anim(scene, [...]) { ... } and the participants' names."""
    m = re.search(r'\banim\(scene, \[([^\]]*)\]\) \{\n(.*?)\n\t\t\}', entry, re.S)
    if not m: return None, None
    names = [n.strip() for n in m.group(1).split(',') if n.strip()]
    return names, m.group(2)

def strip_comments(body):
    return re.sub(r'^\s*//.*$', '', body, flags=re.M)

# ------------------------------------------------------------- spreads ----

def unwrap_spread(names, body):
    """anim(scene, [attacker, ...defenders]) with a loop over the defenders:
    the loop body is kept once with the singular name, the recipe is marked
    spread, and `const x = defenders[1] || defenders[0]` names the primary
    target -- the app plays the per-target part once per target and the rest
    against the first."""
    if len(names) < 2 or not names[1].startswith('...'): return names, body, False, {}
    plural = names[1][3:]; singular = plural[:-1]
    extra = {}
    def primary(m):
        extra[m.group(1)] = 'defender'; return ''
    body = re.sub(r'^\s*const (\w+) = ' + plural + r'\[1\] \|\| ' + plural + r'\[0\];\s*$', primary, body, flags=re.M)
    loop = re.compile(r'\n\t\t\tfor \(const (\w+) of ' + plural + r'\) \{\n(.*?)\n\t\t\t\}', re.S)
    var = None
    def unwrap(m):
        nonlocal var
        var = m.group(1)
        return '\n' + re.sub(r'^\t', '', m.group(2), flags=re.M)
    body = loop.sub(unwrap, body)
    body = body.replace(plural + '[0]', singular).replace(plural + '[1]', singular)
    if plural in body: raise Unparsed('spread: ' + plural + ' used outside its loop')
    if var and var != singular: body = re.sub(r'\b' + var + r'\b', singular, body)
    return [names[0], singular], body, var is not None, extra

# ------------------------------------------------------- declarations ----

def declarations(body):
    """`let xstep = (defender.x - attacker.x) / 5;` and `let xf = [1, -1];`
    -- substituted textually, arrays after the loop counter is known."""
    scalars, arrays = {}, {}
    def take(m):
        name, value = m.group(1), m.group(2).strip()
        if value.startswith('['):
            arrays[name] = [v.strip() for v in value[1:-1].split(',')]
        else:
            scalars[name] = '(' + value + ')'
        return ''
    body = re.sub(r'^\s*(?:let|const|var) (\w+) = ([^;]+);\s*$', take, body, flags=re.M)
    return body, scalars, arrays

def unroll(body, arrays):
    """for (let i = a; i < b; i++) { ... } -> the body once per value of i."""
    loop = re.compile(r'\n(\t+)for \(let (\w+) = (' + NUM + r'); \2 (<|<=) (' + NUM + r'); \2(\+\+|--| \+= (' + NUM + r'))\) \{\n(.*?)\n\1\}', re.S)
    def expand(m):
        var, start, op, stop, step_kind, step = m.group(2), float(m.group(3)), m.group(4), float(m.group(5)), m.group(6), m.group(7)
        inc = 1.0 if step_kind == '++' else -1.0 if step_kind == '--' else float(step)
        inner = m.group(8)
        out = []
        i = start
        guard = 0
        while (i < stop if op == '<' else i <= stop) and guard < 40:
            text = inner
            for name, values in arrays.items():
                text = re.sub(r'\b' + name + r'\[' + var + r'\]', lambda _: values[int(i)] if int(i) < len(values) else '0', text)
                text = re.sub(r'\b' + name + r'\[(\d+)\]', lambda mm: values[int(mm.group(1))], text)
            text = re.sub(r'\b' + var + r'\b', '(' + str(i) + ')', text)
            out.append(text)
            i += inc; guard += 1
        return '\n' + '\n'.join(out)
    previous = None
    while previous != body:
        previous = body
        body = loop.sub(expand, body)
    if re.search(r'\bfor \(', body): raise Unparsed(re.search(r'for \([^)]*\)', body).group(0)[:40])
    return body

# ---------------------------------------------------------- expressions ----

class Linear:
    """a * attacker + d * defender + c, with behind/leftof terms per anchor."""
    def __init__(self, c=0.0, **terms):
        self.c = c; self.t = dict(terms)
    def scaled(self, k):
        out = Linear(self.c * k); out.t = {n: v * k for n, v in self.t.items()}; return out
    def plus(self, other, sign=1):
        out = Linear(self.c + sign * other.c); out.t = dict(self.t)
        for n, v in other.t.items(): out.t[n] = out.t.get(n, 0) + sign * v
        return out
    def constant(self): return not any(abs(v) > 1e-9 for v in self.t.values())

def evaluate(expr, axis, who):
    """Parse an arithmetic expression over the anchors into a Linear."""
    # `**` before the single-character class, or it splits into two `*` and
    # the second one arrives where a number should be. Make It Rain lays its
    # coins out at (-1) ** i * (32 - i * 8), and this is the whole reason it
    # had no animation at all.
    tokens = re.findall(r'\d+\.\d+|\d+|[A-Za-z_]\w*(?:\.\w+)*|\*\*|[()+\-*/]', expr)
    pos = 0
    def peek(): return tokens[pos] if pos < len(tokens) else None
    def take():
        nonlocal pos; pos += 1; return tokens[pos - 1]
    def primary():
        tok = take()
        if tok is None: raise Unparsed('expression: ' + expr)
        if tok == '(':
            v = sum_(); assert take() == ')'; return v
        if tok in '+-':
            v = primary(); return v if tok == '+' else v.scaled(-1)
        if re.fullmatch(r'\d+(?:\.\d+)?', tok): return Linear(float(tok))
        if tok in ('Math.floor', 'Math.round', 'Math.ceil', 'Math.abs'):
            assert take() == '('; v = sum_(); assert take() == ')'; return v
        m = re.fullmatch(r'(\w+)\.(x|y|z|behind|leftof|behindx|behindy)', tok)
        if m and m.group(1) in who:
            anchor, prop = who[m.group(1)], m.group(2)
            if prop in ('x', 'y', 'z'):
                # The same axis is the common case and written bare; the
                # client does occasionally set a y from an x, and draws it.
                return Linear(0.0, **{anchor[0] if prop == axis else anchor[0] + prop: 1.0})
            assert take() == '('; arg = sum_(); assert take() == ')'
            if not arg.constant(): raise Unparsed('offset not constant')
            # behind(n) is the Pokemon's own depth plus n toward its back;
            # leftof(n) its own x plus n to its left. The anchor's weight
            # rides along with the offset.
            key = anchor[0] + ('b' if prop.startswith('behind') else 'l')
            return Linear(0.0, **{anchor[0]: 1.0, key: arg.c})
        raise Unparsed('token ' + tok)
    def power():
        # Constant only, and that is all the client ever needs: by the time a
        # loop has been unrolled the counter is a number, so (-1) ** i is a
        # sign and not an unknown.
        v = primary()
        while peek() == '**':
            take(); w = primary()
            if not (v.constant() and w.constant()):
                raise Unparsed('nonlinear power')
            v = Linear(v.c ** w.c)
        return v

    def product():
        v = power()
        while peek() in ('*', '/'):
            op = take(); w = power()
            if op == '*':
                if w.constant(): v = v.scaled(w.c)
                elif v.constant(): v = w.scaled(v.c)
                else: raise Unparsed('nonlinear')
            else:
                if not w.constant(): raise Unparsed('division')
                if w.c == 0: raise Offscreen('divided by zero')
                v = v.scaled(1 / w.c)
        return v
    def sum_():
        v = product()
        while peek() in ('+', '-'):
            op = take(); v = v.plus(product(), 1 if op == '+' else -1)
        return v
    v = sum_()
    if pos != len(tokens): raise Unparsed('trailing ' + ' '.join(tokens[pos:]))
    return v

def coordinate(expr, axis, who):
    v = evaluate(expr, axis, who)
    out = {}
    for key in ('a', 'd', 'ax', 'ay', 'az', 'dx', 'dy', 'dz', 'ab', 'db', 'al', 'dl'):
        if abs(v.t.get(key, 0)) > 1e-9: out[key] = round(v.t[key], 4)
    if abs(v.c) > 1e-9 or not out: out['c'] = round(v.c, 2)
    return out

def split_top(text, sep=','):
    parts, depth, cur, quote = [], 0, '', None
    for ch in text:
        if quote:
            cur += ch
            if ch == quote: quote = None
            continue
        if ch in '\'"`': quote = ch
        if ch in '({[': depth += 1
        if ch in ')}]': depth -= 1
        if ch == sep and depth == 0: parts.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): parts.append(cur)
    return [p.strip() for p in parts]

def pose(block, who):
    """{ x: ..., y: ..., z: ..., scale: n, opacity: n, time: n } -> dict."""
    block = block.strip()
    if not (block.startswith('{') and block.endswith('}')): raise Unparsed('pose ' + block[:30])
    out = {}
    for p in split_top(block[1:-1]):
        if not p: continue
        m = re.fullmatch(r'(\w+): (.+)', p, re.S)
        if not m: raise Unparsed('field ' + p[:30])
        key, val = m.group(1), m.group(2).strip()
        if key in ('x', 'y', 'z'): out[key] = coordinate(val, key, who)
        elif key in ('scale', 'xscale', 'yscale', 'opacity', 'time'):
            v = evaluate(val, key, who)
            if not v.constant(): raise Unparsed(key + ' not constant')
            out[key] = round(v.c, 3)
        else: raise Unparsed('key ' + key)
    return out

# ----------------------------------------------------------- statements ----

def statements(body):
    out, depth, cur, quote = [], 0, '', None
    for ch in body:
        cur += ch
        if quote:
            if ch == quote: quote = None
            continue
        if ch in '\'"`': quote = ch
        elif ch in '({[': depth += 1
        elif ch in ')}]': depth -= 1
        elif ch == ';' and depth == 0: out.append(cur.strip()); cur = ''
    if cur.strip(): out.append(cur.strip())
    return out

def args(call):
    return split_top(call[call.index('(') + 1: call.rindex(')')])

def unquote(s):
    s = s.strip()
    return s[1:-1] if s[:1] in '\'"`' and s[-1:] == s[:1] else s

EASINGS = ['linear', 'swing', 'accel', 'decel', 'ballistic', 'ballisticUp', 'ballisticUnder',
           'ballistic2', 'ballistic2Under', 'ballistic2Back']

def easing(name):
    """The client's easing names, one spelling each -- it writes
    ballistic2back once and ballistic2Back everywhere else."""
    for known in EASINGS:
        if known.lower() == name.lower(): return known
    return 'linear'

def translate(body, names, extra={}):
    who = {names[0]: 'attacker'}
    if len(names) > 1: who[names[1]] = 'defender'
    who.update(extra)
    def part(n):
        if n not in who: raise Unparsed('participant ' + n)
        return who[n]
    steps = []
    for st in statements(body):
        st = st.strip()
        if not st: continue
        if st.startswith('scene.showEffect('):
            a = args(st)
            if len(a) < 4: raise Unparsed('showEffect args')
            sprite = unquote(a[0])
            if re.fullmatch(r'(\w+)\.sp', sprite): sprite = part(sprite[:-3])
            # A slash drawn one way for the far side and the other for the
            # near: the first is kept, and the renderer mirrors by side.
            m = re.fullmatch(r"\(\w+\.isFrontSprite \? '(\w+)' : '(\w+)'\)", sprite)
            if m: sprite = m.group(1)
            if not re.fullmatch(r'\w+', sprite): raise Unparsed('sprite ' + sprite[:30])
            try:
                step = {'kind': 'effect', 'sprite': sprite, 'from': pose(a[1], who), 'to': pose(a[2], who),
                        'easing': easing(unquote(a[3]))}
            except Offscreen:
                # The client draws this one where it cannot be seen. Leaving
                # it out is what it looks like; leaving the move out is not.
                continue
            if len(a) > 4 and a[4].startswith(("'", '"')): step['ending'] = unquote(a[4])
            steps.append(step)
        elif re.match(r'(\w+)\.delay\((' + NUM + r')\)\.anim\(', st):
            m = re.match(r'(\w+)\.delay\((' + NUM + r')\)\.anim\(', st)
            steps.append({'kind': 'delay', 'who': part(m.group(1)), 'ms': round(float(m.group(2)))})
            a = args(st[st.index('.anim(') + 5:])
            step = {'kind': 'move', 'who': part(m.group(1)), 'to': pose(a[0], who)}
            if len(a) > 1: step['easing'] = easing(unquote(a[1]))
            steps.append(step)
        elif re.match(r'(\w+)\.anim\(', st):
            n = re.match(r'(\w+)\.anim\(', st).group(1); a = args(st)
            step = {'kind': 'move', 'who': part(n), 'to': pose(a[0], who)}
            if len(a) > 1: step['easing'] = easing(unquote(a[1]))
            steps.append(step)
        elif re.match(r'(\w+)\.delay\(', st):
            n = re.match(r'(\w+)\.delay\(', st).group(1); v = evaluate(args(st)[0], 'time', who)
            steps.append({'kind': 'delay', 'who': part(n), 'ms': round(v.c)})
        elif st.startswith('scene.wait('):
            steps.append({'kind': 'wait', 'ms': round(evaluate(args(st)[0], 'time', who).c)})
        elif st.startswith('scene.backgroundEffect('):
            a = args(st)
            colour = unquote(a[0])
            nums = [evaluate(x, 'time', who).c for x in a[1:]]
            step = {'kind': 'background', 'duration': nums[0], 'opacity': nums[1]}
            if len(nums) > 2: step['delay'] = nums[2]
            m = re.search(r'/fx/([\w-]+)\.\w+', colour)
            if m: step['image'] = m.group(1)
            else: step['colour'] = colour
            steps.append(step)
        elif st.startswith('scene.$bg.'):
            total = sum(float(x) for x in re.findall(r'\}, (' + NUM + r')\)', st))
            pause = re.match(r'scene\.\$bg\.delay\((' + NUM + r')\)', st)
            step = {'kind': 'shake', 'ms': round(total)}
            if pause: step['delay'] = round(float(pause.group(1)))
            steps.append(step)
        elif re.match(r'Battle(Other|Move)Anims(?:\.(\w+)|\[.(\w+).\])\.anim\(scene, \[([^\]]*)\]\)', st):
            m = re.match(r'Battle(Other|Move)Anims(?:\.(\w+)|\[.(\w+).\])\.anim\(scene, \[([^\]]*)\]\)', st)
            parts = [part(p.strip()) for p in m.group(4).split(',') if p.strip()]
            steps.append({'kind': 'include', 'table': 'other' if m.group(1) == 'Other' else 'moves',
                          'name': m.group(2) or m.group(3), 'parts': parts})
        else:
            raise Unparsed(st[:40])
    return steps

def recipe(entry):
    names, body = anim_body(entry)
    if body is None: raise Unparsed('no anim')
    body = '\n' + strip_comments(body)
    names, body, spread, extra = unwrap_spread(names, body)
    body, scalars, arrays = declarations(body)
    # Put the declarations back before the loops are unrolled as well as
    # after. One written *inside* a loop carries the counter in it -- Make It
    # Rain lays its coins at `const hitPos = (-1) ** i * (32 - i * 8)` -- and
    # substituting it only afterwards leaves an `i` in an expression that has
    # to be a number by then, which is a whole animation lost to an ordering.
    def settle(text):
        for _ in range(3):
            for name, value in scalars.items():
                text = re.sub(r'\b' + name + r'\b', value, text)
        return text
    body = settle(body)
    body = unroll(body, arrays)
    body = settle(body)
    out = {'steps': translate(body, names, extra)}
    if spread: out['spread'] = True
    return out

def table(text, label):
    out, failed = {}, {}
    for name, entry in entries(text).items():
        borrowed = alias(entry)
        if borrowed: out[name] = {'alias': borrowed[0] + ':' + borrowed[1]}; continue
        try: out[name] = recipe(entry)
        except Unparsed as e: failed[name] = str(e)
        except (AssertionError, IndexError, ValueError) as e: failed[name] = 'syntax ' + repr(e)[:40]
    # After the table, three hundred more moves borrow a recipe by assignment:
    #     BattleMoveAnims['doubleedge'] = { anim: BattleMoveAnims['gigaimpact'].anim };
    #     BattleMoveAnims['torment'] = BattleMoveAnims['swagger'];
    for m in re.finditer(r"^Battle(Move|Other)Anims\['(\w+)'\] = (?:\{ ?anim: )?Battle(Move|Other)Anims\['(\w+)'\](?:\.anim)?;?", text, re.M):
        if (m.group(1) == 'Move') == (label == 'moves'):
            out[m.group(2)] = {'alias': ('moves' if m.group(3) == 'Move' else 'other') + ':' + m.group(4)}
            failed.pop(m.group(2), None)
    return out, failed

def sprite_sizes(text):
    """The drawn size of each primitive, from the client's own table."""
    block = section(text, 'const BattleEffects')
    sizes = {}
    for m in re.finditer(r'^\t(\w+): \{\n(.*?)^\t\},', block, re.S | re.M):
        w = re.search(r'\bw: (\d+)', m.group(2)); h = re.search(r'\bh: (\d+)', m.group(2))
        if w and h: sizes[m.group(1)] = [int(w.group(1)), int(h.group(1))]
    return sizes

# ---------------------------------------------------------------- main ----

moves_src = open(MOVES, encoding='utf-8').read()
other_src = open(OTHER, encoding='utf-8').read()
moves, moves_failed = table(moves_src, 'moves')
other, other_failed = table(section(other_src, 'const BattleOtherAnims'), 'other')
status, status_failed = table(section(other_src, 'export const BattleStatusAnims'), 'status')
sizes = sprite_sizes(other_src)

def resolves(ref, seen=()):
    t, n = ref.split(':'); tab = {'other': other, 'moves': moves}[t]
    if n not in tab or ref in seen: return False
    r = tab[n]
    if 'alias' in r: return resolves(r['alias'], seen + (ref,))
    return all(resolves(s['table'] + ':' + s['name'], seen + (ref,)) for s in r['steps'] if s['kind'] == 'include')
for tab, failed, label in ((moves, moves_failed, 'moves'), (other, other_failed, 'other')):
    for name in list(tab):
        if not resolves(label + ':' + name): failed[name] = 'dangling reference'; del tab[name]

used = {s['sprite'] for t in (moves, other, status) for r in t.values()
        for s in r.get('steps', []) if s['kind'] == 'effect'}
sprites = {name: sizes.get(name, [100, 100]) for name in sorted(used) if name not in ('attacker', 'defender')}
sys.stdout.write(json.dumps({
    'source': 'pokemon-showdown-client, play.pokemonshowdown.com/src/battle-animations-moves.ts and battle-animations.ts (MIT)',
    'moves': moves, 'other': other, 'status': status, 'sprites': sprites,
}, separators=(',', ':')) + '\n')
sys.stderr.write(f'animations: {len(moves)} moves ({len(moves_failed)} left out), {len(other)} fallbacks, {len(status)} status, {len(sprites)} sprites\n')
sys.stderr.write('  left out because: ' + ', '.join(f'{k} x{v}' for k, v in Counter(v.split(' ')[0] for v in moves_failed.values()).most_common(6)) + '\n')
if "--why" in sys.argv:
    for k, v in sorted(other_failed.items()): sys.stderr.write(f"    other/{k}: {v}\n")
    for k, v in sorted(moves_failed.items()): sys.stderr.write(f'    {k}: {v}\n')
