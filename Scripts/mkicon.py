"""Generate icon-1024.png for ChampionsLab.app — a Mega-Evolution rhombus.

Pure stdlib: signed-distance shapes sampled once per pixel (clean antialiasing)
written out through a hand-rolled PNG encoder, so the build needs no Pillow.
Same approach as SpoofMAC/mkicon.py.
"""
import zlib, struct, math

S = 1024
buf = bytearray(S * S * 4)


def clamp(v, a=0.0, b=1.0):
    return a if v < a else (b if v > b else v)


def blend(x, y, col, a):
    if a <= 0:
        return
    i = (y * S + x) * 4
    da = buf[i + 3] / 255.0
    oa = a + da * (1 - a)
    if oa <= 0:
        return
    for k in range(3):
        d = buf[i + k] / 255.0
        buf[i + k] = int(round(((col[k] * a + d * da * (1 - a)) / oa) * 255))
    buf[i + 3] = int(round(oa * 255))


def paint(x0, y0, x1, y1, sdf, colfn):
    """Fill where sdf(x, y) < 0, antialiased over the last half pixel."""
    x0, x1 = max(0, int(x0)), min(S - 1, int(x1))
    y0, y1 = max(0, int(y0)), min(S - 1, int(y1))
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            a = clamp(0.5 - sdf(x + 0.5, y + 0.5))
            if a > 0:
                blend(x, y, colfn(x, y), a)


def rrect(cx, cy, hw, hh, r, colfn, angle=0.0):
    ca, sa = math.cos(-angle), math.sin(-angle)

    def sdf(x, y):
        dx, dy = x - cx, y - cy
        px, py = dx * ca - dy * sa, dx * sa + dy * ca
        qx, qy = abs(px) - (hw - r), abs(py) - (hh - r)
        return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r

    reach = math.hypot(hw, hh) + 2
    paint(cx - reach, cy - reach, cx + reach, cy + reach, sdf, colfn)


def ellipse(cx, cy, rx, ry, colfn):
    def sdf(x, y):
        dx, dy = (x - cx) / rx, (y - cy) / ry
        return (math.hypot(dx, dy) - 1.0) * min(rx, ry)

    paint(cx - rx - 2, cy - ry - 2, cx + rx + 2, cy + ry + 2, sdf, colfn)


def rhombus(cx, cy, hw, hh, colfn, round_r=0.0):
    """A diamond. The Mega Evolution emblem is built from two of these."""
    def sdf(x, y):
        # Distance to a rhombus, from the standard |x|/hw + |y|/hh <= 1 form,
        # normalised so the falloff is roughly in pixels.
        px, py = abs(x - cx), abs(y - cy)
        f = px / hw + py / hh - 1.0
        scale = 1.0 / math.hypot(1.0 / hw, 1.0 / hh)
        return f * scale - round_r

    reach = max(hw, hh) + round_r + 2
    paint(cx - reach, cy - reach, cx + reach, cy + reach, sdf, colfn)


def solid(c):
    return lambda x, y: c


def vgrad(top, bot, y0, y1):
    def f(x, y):
        t = clamp((y - y0) / float(y1 - y0))
        return [top[k] + (bot[k] - top[k]) * t for k in range(3)]
    return f


def dgrad(a, b, x0, y0, x1, y1):
    """Gradient along an arbitrary axis, for the emblem's sheen."""
    dx, dy = x1 - x0, y1 - y0
    denom = float(dx * dx + dy * dy) or 1.0

    def f(x, y):
        t = clamp(((x - x0) * dx + (y - y0) * dy) / denom)
        return [a[k] + (b[k] - a[k]) * t for k in range(3)]
    return f


def hexc(h):
    h = h.lstrip('#')
    return [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]


INDIGO_TOP, INDIGO_BOT = hexc('3B3A8C'), hexc('16143A')
CYAN, MAGENTA = hexc('4FD8E8'), hexc('E8559B')
WHITE = hexc('FFFFFF')

# Rounded-square app tile with the standard macOS margin. Held onto, because
# punching a hole means repainting the tile gradient at those pixels.
TILE = vgrad(INDIGO_TOP, INDIGO_BOT, 100, 924)
rrect(512, 512, 412, 412, 190, TILE)

# The Mega Evolution emblem: a tall rhombus, split into a bright upper half and
# a darker lower one. Reads as a gem, and stays legible down to 16px because it
# is one silhouette rather than a cluster of shapes.
SHEEN = dgrad(CYAN, MAGENTA, 320, 260, 704, 764)
rhombus(512, 512, 236, 320, SHEEN)

# Inner facet, punched back to the tile so the emblem looks cut rather than flat.
rhombus(512, 512, 132, 182, TILE)

# The horizontal split that makes it the Mega mark and not just a diamond.
rrect(512, 512, 250, 17, 8, TILE)

# Two spark points on the long axis, the shorthand for "evolving".
ellipse(512, 512 - 246, 26, 34, solid(WHITE))
ellipse(512, 512 + 246, 26, 34, solid(WHITE))


def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))


raw = b''.join(b'\x00' + bytes(buf[y * S * 4:(y + 1) * S * 4]) for y in range(S))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', S, S, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 9))
       + chunk(b'IEND', b''))
open('icon-1024.png', 'wb').write(png)
print('wrote icon-1024.png', len(png), 'bytes')
