#!/usr/bin/env python3
"""The covers of the made-up games the showcase site shows, as SVG.

    python3 site/covers/make_covers.py        # writes site/covers/*.svg

The site shows Cartouche's screens with games and covers we invent: cover art
of real games is not ours to publish (docs/decisions.md, 12 and 37). Each
cover has a game case's proportions, Cartouche's CartoucheTheme.labelAspect
(0.68), and draws only shapes, gradients and the game's name. The random
parts (stars, fireflies, ridges) come from a fixed seed, so the files only
change when this script does.
"""

import math
import random
from pathlib import Path

W, H = 340, 500
OUT = Path(__file__).resolve().parent

ROUNDED = "ui-rounded, 'SF Pro Rounded', 'Arial Rounded MT Bold', system-ui, sans-serif"
SERIF = "'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif"
CAPS = "Optima, Candara, 'Iowan Old Style', Georgia, serif"
WIDE = "'Avenir Next', Futura, 'Trebuchet MS', 'Segoe UI', system-ui, sans-serif"


def f(x: float) -> str:
    return f"{x:.1f}".rstrip("0").rstrip(".")


def stops(*pairs) -> str:
    out = []
    for pair in pairs:
        offset, color = pair[0], pair[1]
        opacity = f' stop-opacity="{pair[2]}"' if len(pair) > 2 else ""
        out.append(f'<stop offset="{offset}" stop-color="{color}"{opacity}/>')
    return "".join(out)


def linear(name: str, *pairs, x2: float = 0, y2: float = 1) -> str:
    return f'<linearGradient id="{name}" x1="0" y1="0" x2="{x2}" y2="{y2}">{stops(*pairs)}</linearGradient>'


def radial(name: str, *pairs, cx: float = 0.5, cy: float = 0.5, r: float = 0.5) -> str:
    return f'<radialGradient id="{name}" cx="{cx}" cy="{cy}" r="{r}">{stops(*pairs)}</radialGradient>'


def blur(name: str, deviation: float) -> str:
    return (f'<filter id="{name}" x="-50%" y="-50%" width="200%" height="200%">'
            f'<feGaussianBlur stdDeviation="{deviation}"/></filter>')


SHADOW = ('<filter id="shadow" x="-20%" y="-40%" width="140%" height="180%">'
          '<feDropShadow dx="0" dy="2" stdDeviation="2.5" flood-color="#000" flood-opacity=".45"/></filter>')


def stars(rng: random.Random, count: int, top: float, bottom: float, color: str = "#FFFFFF") -> str:
    out = []
    for _ in range(count):
        x, y = rng.uniform(4, W - 4), rng.uniform(top, bottom)
        r = rng.choice((0.6, 0.7, 0.8, 1.0, 1.2, 1.5))
        out.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{r}" fill="{color}" opacity="{rng.uniform(.35, 1):.2f}"/>')
    return "".join(out)


def ridge(rng: random.Random, base: float, rough: float, steps: int = 7, left: float = -10, right: float = W + 10) -> list:
    """A mountain ridge by midpoint displacement, as points from left to right."""
    points = [(left, base + rng.uniform(-rough, rough)), (right, base + rng.uniform(-rough, rough))]
    spread = rough
    for _ in range(steps):
        refined = [points[0]]
        for a, b in zip(points, points[1:]):
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + rng.uniform(-spread, spread))
            refined += [mid, b]
        points = refined
        spread *= 0.55
    return points


def polygon_below(points: list, bottom: float, fill: str, extra: str = "") -> str:
    path = "M" + " L".join(f"{f(x)} {f(y)}" for x, y in points)
    path += f" L{f(points[-1][0])} {bottom} L{f(points[0][0])} {bottom} Z"
    return f'<path d="{path}" fill="{fill}"{extra}/>'


def sparkle(x: float, y: float, size: float, opacity: float) -> str:
    s, t = size, size * 0.22
    return (f'<path d="M{f(x)} {f(y - s)} L{f(x + t)} {f(y - t)} L{f(x + s)} {f(y)} L{f(x + t)} {f(y + t)} '
            f'L{f(x)} {f(y + s)} L{f(x - t)} {f(y + t)} L{f(x - s)} {f(y)} L{f(x - t)} {f(y - t)} Z" '
            f'fill="#FFFFFF" opacity="{opacity:.2f}"/>')


def svg(title: str, defs: str, body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'role="img" aria-label="{title}">\n'
            f'<title>{title}</title>\n<defs>{defs}</defs>\n{body}\n</svg>\n')


def aurora_rally() -> str:
    rng = random.Random(11)
    horizon = 338
    defs = (linear("sky", (0, "#05081F"), (.42, "#121648"), (.6, "#33195E"), (.66, "#6A2A74"), (.68, "#2A1550"))
            + linear("ground", (0, "#0E0B26"), (1, "#05040F"))
            + linear("road", (0, "#1C1740"), (1, "#2C2358"))
            + linear("teal", (0, "#2EF2B8", 0), (.55, "#2EF2B8", .9), (1, "#2EF2B8", 0))
            + linear("violet", (0, "#A47BFF", 0), (.5, "#A47BFF", .75), (1, "#A47BFF", 0))
            + linear("rally", (0, "#FF4FA3"), (1, "#FFB347"), x2=1, y2=0)
            + linear("tail", (0, "#FF3D6E"), (1, "#FF9A3D"), x2=1, y2=0)
            + blur("soft", 5) + blur("glow", 3.5) + SHADOW
            + '<pattern id="curtain" width="7" height="40" patternUnits="userSpaceOnUse">'
              '<rect width="2" height="40" fill="#FFFFFF" opacity=".16"/></pattern>'
            + '<clipPath id="ribbon"><path d="M-20 170 C40 120 90 200 160 150 S280 92 360 140 L360 214 '
              'C290 172 230 240 160 214 S40 200 -20 250 Z"/></clipPath>')
    far = ridge(rng, horizon - 16, 16, steps=6)
    near = ridge(rng, horizon - 4, 7, steps=6)
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>', stars(rng, 70, 8, 300)]
    body.append('<g filter="url(#soft)">'
                '<path d="M-20 170 C40 120 90 200 160 150 S280 92 360 140 L360 214 C290 172 230 240 160 214 '
                'S40 200 -20 250 Z" fill="url(#teal)"/>'
                '<path d="M-20 222 C60 186 120 252 200 220 S300 176 360 204 L360 250 C300 238 230 288 150 266 '
                'S40 268 -20 292 Z" fill="url(#violet)"/></g>')
    body.append('<rect width="340" height="300" fill="url(#curtain)" clip-path="url(#ribbon)" opacity=".7"/>')
    body.append(polygon_below(far, horizon + 4, "#16133D"))
    body.append(polygon_below(near, horizon + 4, "#0B0A24"))
    body.append(f'<rect y="{horizon}" width="{W}" height="{H - horizon}" fill="url(#ground)"/>')
    body.append(f'<path d="M163 {horizon} L177 {horizon} L338 500 L2 500 Z" fill="url(#road)"/>')
    body.append(f'<path d="M163 {horizon} L2 500 M177 {horizon} L338 500" stroke="#8A7CFF" stroke-opacity=".55" stroke-width="1.6"/>')
    dashes = []
    for t1, t2 in ((.03, .06), (.1, .15), (.21, .29), (.38, .5), (.63, .8), (.95, 1.2)):
        y1, y2 = horizon + 162 * t1, horizon + 162 * min(t2, 1.03)
        w1, w2 = 0.6 + 6 * t1, 0.6 + 6 * t2
        dashes.append(f'<path d="M{f(170 - w1)} {f(y1)} L{f(170 + w1)} {f(y1)} L{f(170 + w2)} {f(y2)} L{f(170 - w2)} {f(y2)} Z"/>')
    body.append(f'<g fill="#FFE9A8" opacity=".85">{"".join(dashes)}</g>')
    trails = ('<path d="M92 500 C118 440 150 386 168 342" stroke="#FF4FA3"/>'
              '<path d="M248 500 C222 440 190 386 172 342" stroke="#FFB347"/>')
    body.append(f'<g fill="none" stroke-linecap="round"><g stroke-width="9" opacity=".75" filter="url(#glow)">{trails}</g>'
                f'<g stroke-width="2.6">{trails}</g></g>')
    # The player's car, from behind, on the right lane.
    body.append('<g transform="translate(206 404)">'
                '<ellipse cx="30" cy="40" rx="36" ry="6" fill="#000" opacity=".45"/>'
                '<path d="M10 14 L16 2 Q18 -2 23 -2 L37 -2 Q42 -2 44 2 L50 14 Z" fill="#241C4D"/>'
                '<path d="M17 12 L21 3 L39 3 L43 12 Z" fill="#6E6BD8" opacity=".55"/>'
                '<rect x="0" y="12" width="60" height="24" rx="7" fill="#3A2F7A"/>'
                '<rect x="0" y="12" width="60" height="7" rx="3.5" fill="#4E43A0"/>'
                '<g filter="url(#glow)"><rect x="4" y="21" width="15" height="6" rx="3" fill="url(#tail)"/>'
                '<rect x="41" y="21" width="15" height="6" rx="3" fill="url(#tail)"/></g>'
                '<rect x="4" y="21" width="15" height="6" rx="3" fill="#FFC1D2"/>'
                '<rect x="41" y="21" width="15" height="6" rx="3" fill="#FFC1D2"/>'
                '<rect x="22" y="23" width="16" height="7" rx="1.5" fill="#E9E6FF"/>'
                '<rect x="3" y="34" width="12" height="6" rx="2" fill="#120E26"/>'
                '<rect x="45" y="34" width="12" height="6" rx="2" fill="#120E26"/></g>')
    body.append(f'<g filter="url(#shadow)" text-anchor="middle">'
                f'<text x="170" y="76" font-family="{WIDE}" font-weight="900" font-style="italic" font-size="57" '
                f'letter-spacing="1" fill="#FFFFFF" transform="skewX(-6) translate(18 0)">AURORA</text>'
                f'<text x="170" y="110" font-family="{WIDE}" font-weight="800" font-size="24" letter-spacing="15" '
                f'fill="url(#rally)">RALLY</text></g>')
    body.append('<g stroke="url(#rally)" stroke-width="2.4" stroke-linecap="round">'
                '<path d="M62 102 H90 M70 110 H90"/><path d="M250 102 H278 M250 110 H270"/></g>')
    return svg("Aurora Rally", defs, "\n".join(body))


def lanterne() -> str:
    rng = random.Random(23)
    sea = 372
    defs = (linear("sky", (0, "#1B1446"), (.3, "#3E2266"), (.52, "#9C3A6E"), (.66, "#E8705E"), (.745, "#FFB46B"))
            + linear("sea", (0, "#3A2A66"), (.4, "#22184A"), (1, "#0F0B26"))
            + radial("sun", (0, "#FFF6D8"), (.7, "#FFD08A"), (1, "#FFB46B"))
            + radial("halo", (0, "#FFB46B", .55), (1, "#FFB46B", 0))
            + radial("lamp", (0, "#FFF4C2", 1), (.4, "#FFE08A", .6), (1, "#FFE08A", 0))
            + linear("beam", (0, "#FFF0B8", .62), (1, "#FFF0B8", 0), x2=1, y2=0)
            + linear("beamleft", (0, "#FFF0B8", 0), (1, "#FFF0B8", .35), x2=1, y2=0)
            + linear("title", (0, "#FFF7E8"), (1, "#FFD9A8"))
            + SHADOW)
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>', stars(rng, 40, 8, 160, "#FFEFD8")]
    body.append('<circle cx="238" cy="372" r="118" fill="url(#halo)"/>')
    body.append('<circle cx="238" cy="372" r="52" fill="url(#sun)"/>')
    body.append(f'<rect y="{sea}" width="{W}" height="{H - sea}" fill="url(#sea)"/>')
    glints = []
    for i in range(11):
        y = sea + 8 + i * 9.5
        half = max(6.0, 44 - i * 3.6 + rng.uniform(-4, 4))
        dx = rng.uniform(-6, 6)
        glints.append(f'<path d="M{f(238 - half + dx)} {f(y)} H{f(238 + half + dx)}" opacity="{max(.12, .9 - i * .075):.2f}"/>')
    body.append(f'<g stroke="#FFD59A" stroke-width="2.4" stroke-linecap="round">{"".join(glints)}</g>')
    body.append('<path d="M80 198 L340 128 L340 238 Z" fill="url(#beam)"/>')
    body.append('<path d="M60 198 L0 172 L0 220 Z" fill="url(#beamleft)"/>')
    body.append('<path d="M0 302 L18 297 C42 291 72 293 104 299 C121 302 128 313 135 331 '
                'C143 352 151 372 162 392 L176 500 L0 500 Z" fill="#140B29"/>')
    body.append('<path d="M0 302 L18 297 C42 291 72 293 104 299 C121 302 128 313 135 331" fill="none" '
                'stroke="#FF8F6B" stroke-opacity=".45" stroke-width="1.6"/>')
    # The lighthouse: a tapering tower, two red bands, its gallery and lantern.
    def tower_x(y: float) -> tuple:
        t = (296 - y) / (296 - 214)
        return 57 + 5 * t, 83 - 5 * t
    bands = []
    for top, bottom in ((236, 249), (266, 279)):
        lt, rt = tower_x(top)
        lb, rb = tower_x(bottom)
        bands.append(f'<path d="M{f(lt)} {top} L{f(rt)} {top} L{f(rb)} {bottom} L{f(lb)} {bottom} Z"/>')
    body.append('<path d="M57 296 L83 296 L78 214 L62 214 Z" fill="#F4EEE8"/>')
    body.append(f'<g fill="#D9465B">{"".join(bands)}</g>')
    body.append('<path d="M70 214 L78 214 L83 296 L70 296 Z" fill="#2A1B3D" opacity=".18"/>')
    body.append('<circle cx="70" cy="199" r="30" fill="url(#lamp)"/>')
    body.append('<rect x="55" y="208" width="30" height="6" rx="1.5" fill="#2A1B3D"/>'
                '<rect x="61" y="190" width="18" height="18" rx="2" fill="#FFE7A3"/>'
                '<path d="M67 190 V208 M73 190 V208" stroke="#C79A5A" stroke-width="1.2"/>'
                '<path d="M58 191 Q70 172 82 191 Z" fill="#2A1B3D"/>'
                '<path d="M70 177 V168" stroke="#2A1B3D" stroke-width="2" stroke-linecap="round"/>')
    birds = []
    for x, y, s in ((226, 132, 1), (246, 146, .8), (212, 156, .7), (262, 120, .6)):
        birds.append(f'<path d="M{f(x)} {f(y)} q{f(5 * s)} {f(-5 * s)} {f(10 * s)} 0 q{f(5 * s)} {f(-5 * s)} {f(10 * s)} 0"/>')
    body.append(f'<g fill="none" stroke="#2B1838" stroke-width="1.8" stroke-linecap="round">{"".join(birds)}</g>')
    body.append(f'<g filter="url(#shadow)"><text x="170" y="458" text-anchor="middle" font-family="{SERIF}" '
                f'font-style="italic" font-weight="600" font-size="68" fill="url(#title)">Lanterne</text></g>')
    body.append('<g fill="#FFD9A8" opacity=".9"><path d="M110 476 H156 M184 476 H230" stroke="#FFD9A8" stroke-width="1.4"/>'
                '<path d="M170 471 L175 476 L170 481 L165 476 Z"/></g>')
    return svg("Lanterne", defs, "\n".join(body))


def mosslight() -> str:
    rng = random.Random(37)
    defs = (linear("sky", (0, "#031A1C"), (.5, "#08332C"), (1, "#0B241D"))
            + radial("moonglow", (0, "#9BFFD0", .38), (1, "#9BFFD0", 0))
            + radial("shroom", (0, "#C8FF8A", .75), (1, "#C8FF8A", 0))
            + radial("spirit", (0, "#FBFFF2"), (.6, "#D7FBE4"), (1, "#9EEBC0"))
            + radial("aura", (0, "#D9FFC2", .55), (1, "#D9FFC2", 0))
            + linear("title", (0, "#F1FFB8"), (1, "#7BE36A"))
            + blur("glow", 2.2) + blur("bigglow", 7) + SHADOW)
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>',
            '<circle cx="278" cy="150" r="130" fill="url(#moonglow)"/>',
            '<circle cx="278" cy="150" r="22" fill="#EFFFF4" opacity=".92"/>',
            stars(rng, 24, 10, 150, "#DFFFF0")]

    def pines(base: float, count: int, low: float, high: float, color: str, seed: int) -> str:
        r = random.Random(seed)
        shapes = []
        x = -20.0
        while x < W + 20 and len(shapes) < count:
            height = r.uniform(low, high)
            width = height * r.uniform(.36, .46)
            tiers = []
            for k in range(3):
                top = base - height + k * height * .26
                half = width / 2 * (0.62 + k * .19)
                bottom = top + height * .44
                tiers.append(f'M{f(x)} {f(top)} L{f(x + half)} {f(bottom)} L{f(x - half)} {f(bottom)} Z')
            shapes.append(" ".join(tiers) + f' M{f(x - 3)} {f(base - height * .2)} H{f(x + 3)} V{base} H{f(x - 3)} Z')
            x += width * r.uniform(.55, .85)
        return f'<path d="{" ".join(shapes)}" fill="{color}"/>'

    body.append(pines(318, 18, 120, 190, "#0F4A3B", 5))
    body.append(f'<rect y="300" width="{W}" height="80" fill="#0F4A3B"/>')
    body.append(pines(366, 16, 110, 170, "#0A3A2E", 9))
    body.append(f'<rect y="350" width="{W}" height="40" fill="#0A3A2E"/>')
    body.append('<path d="M0 384 C60 364 120 398 180 380 S300 362 340 374 L340 500 L0 500 Z" fill="#072A21"/>')
    shrooms, glows = [], []
    for x, y, s, cap in ((58, 398, 1.15, "#B9FF6E"), (90, 405, .7, "#7DFFC4"), (262, 391, 1.05, "#7DFFC4"),
                         (290, 401, .7, "#B9FF6E"), (228, 409, .55, "#B9FF6E"), (122, 412, .5, "#7DFFC4")):
        glows.append(f'<circle cx="{x}" cy="{f(y - 16 * s)}" r="{f(26 * s)}" fill="url(#shroom)"/>')
        shrooms.append(f'<rect x="{f(x - 3 * s)}" y="{f(y - 15 * s)}" width="{f(6 * s)}" height="{f(15 * s)}" rx="{f(2 * s)}" fill="#D8FFEE"/>'
                       f'<path d="M{f(x - 15 * s)} {f(y - 13 * s)} Q{x} {f(y - 36 * s)} {f(x + 15 * s)} {f(y - 13 * s)} Z" fill="{cap}"/>'
                       f'<circle cx="{f(x - 5 * s)}" cy="{f(y - 21 * s)}" r="{f(2 * s)}" fill="#FFFFFF" opacity=".7"/>'
                       f'<circle cx="{f(x + 4 * s)}" cy="{f(y - 25 * s)}" r="{f(1.5 * s)}" fill="#FFFFFF" opacity=".6"/>')
    body += glows + shrooms
    flies = []
    for _ in range(30):
        x, y = rng.uniform(14, W - 14), rng.uniform(150, 372)
        flies.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{rng.choice((1.2, 1.6, 2, 2.4))}" opacity="{rng.uniform(.55, 1):.2f}"/>')
    body.append(f'<g fill="#EAFFA0"><g filter="url(#glow)">{"".join(flies)}</g>{"".join(flies)}</g>')
    # The spirit the player leads through the forest.
    body.append('<ellipse cx="170" cy="400" rx="30" ry="6" fill="#031A14" opacity=".7"/>'
                '<circle cx="170" cy="356" r="58" fill="url(#aura)"/>'
                '<path d="M170 316 C196 316 206 344 204 366 C202 388 188 396 170 396 C152 396 138 388 136 366 '
                'C134 344 144 316 170 316 Z" fill="url(#spirit)"/>'
                '<ellipse cx="160" cy="356" rx="4.2" ry="6.2" fill="#0B2A22"/>'
                '<ellipse cx="181" cy="356" rx="4.2" ry="6.2" fill="#0B2A22"/>'
                '<circle cx="161.6" cy="353.6" r="1.4" fill="#FFFFFF"/><circle cx="182.6" cy="353.6" r="1.4" fill="#FFFFFF"/>'
                '<path d="M163 371 Q170 376 178 371" fill="none" stroke="#0B2A22" stroke-width="2" stroke-linecap="round"/>'
                '<path d="M170 318 C168 304 174 294 186 290 C186 302 180 312 170 318 Z" fill="#6EE38A"/>'
                '<path d="M170 318 C176 308 180 300 186 290" fill="none" stroke="#3FB868" stroke-width="1.2"/>')
    body.append(f'<g text-anchor="middle" font-family="{ROUNDED}" font-weight="800" font-size="47" letter-spacing="2">'
                f'<text x="170" y="84" fill="#B9FF6E" filter="url(#bigglow)" opacity=".6">MOSSLIGHT</text>'
                f'<text x="170" y="84" fill="url(#title)" filter="url(#shadow)">MOSSLIGHT</text></g>')
    return svg("Mosslight", defs, "\n".join(body))


def ironveil() -> str:
    rng = random.Random(41)
    defs = (linear("sky", (0, "#12030C"), (.36, "#4A0B24"), (.6, "#9C1F35"), (.78, "#D84B3A"), (.84, "#E9783E"))
            + radial("moon", (0, "#FFF8E8"), (.75, "#F7E6C2"), (1, "#EBCF9E"))
            + radial("halo", (0, "#FFD9A0", .42), (1, "#FFD9A0", 0))
            + linear("gold", (0, "#FFEDB8"), (.5, "#F2C66B"), (1, "#C98A2E"))
            + linear("blade", (0, "#F4F7FB"), (1, "#8E9AAE"), x2=1, y2=0)
            + linear("ground", (0, "#16040C"), (1, "#070104"))
            + SHADOW)
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>', stars(rng, 36, 6, 150, "#FFE6D0"),
            '<circle cx="170" cy="210" r="160" fill="url(#halo)"/>',
            '<circle cx="170" cy="210" r="96" fill="url(#moon)"/>']
    craters = []
    for _ in range(9):
        a, d = rng.uniform(0, math.tau), rng.uniform(10, 74)
        craters.append(f'<circle cx="{f(170 + d * math.cos(a))}" cy="{f(210 + d * math.sin(a))}" r="{f(rng.uniform(4, 13))}"/>')
    body.append(f'<g fill="#DCBF8C" opacity=".38">{"".join(craters)}</g>')
    bats = []
    for x, y, s in ((96, 132, 1), (120, 112, .7), (238, 104, .8), (74, 162, .55)):
        bats.append(f'<path transform="translate({x} {y}) scale({s})" d="M0 0 C-4 -6 -12 -8 -18 -4 C-14 -3 -12 0 -12 3 '
                    f'C-9 0 -5 0 -3 3 L0 1 L3 3 C5 0 9 0 12 3 C12 0 14 -3 18 -4 C12 -8 4 -6 0 0 Z"/>')
    body.append(f'<g fill="#1A040C">{"".join(bats)}</g>')
    # The castle: a wall, five towers with pointed roofs, the keep in the middle.
    towers = ((44, 30, 286, 250), (96, 26, 300, 270), (148, 44, 238, 178), (214, 26, 296, 266), (258, 36, 272, 234))
    parts = ["M24 404 V332 H316 V404 Z"]
    for x, w, top, apex in towers:
        parts.append(f"M{x} 404 V{top} H{x + w} V404 Z")
        parts.append(f"M{x - 4} {top + 1} L{f(x + w / 2)} {apex} L{x + w + 4} {top + 1} Z")
    for i in range(14):
        parts.append(f"M{28 + i * 21} 332 V322 H{38 + i * 21} V332 Z")
    body.append(f'<path d="{" ".join(parts)}" fill="#14040A"/>')
    flags = []
    for x, w, top, apex in towers:
        cx = x + w / 2
        flags.append(f'<path d="M{f(cx)} {apex} V{apex - 16}" stroke="#14040A" stroke-width="1.6"/>'
                     f'<path d="M{f(cx)} {apex - 16} L{f(cx + 12)} {apex - 12} L{f(cx)} {apex - 8} Z" fill="#C2283F"/>')
    body.append("".join(flags))
    windows = []
    for x, y in ((161, 262), (175, 262), (168, 296), (55, 316), (104, 326), (220, 320), (272, 300), (124, 360), (210, 362)):
        windows.append(f'<rect x="{x}" y="{y}" width="6" height="10" rx="3"/>')
    body.append(f'<g fill="#FFB45C">{"".join(windows)}</g>')
    body.append('<path d="M0 404 C60 390 120 414 170 402 S280 392 340 406 L340 500 L0 500 Z" fill="url(#ground)"/>')
    # The sword in the ground, in front.
    body.append('<ellipse cx="170" cy="440" rx="26" ry="5" fill="#000" opacity=".5"/>'
                '<path d="M163 306 L177 306 L175 438 L170 446 L165 438 Z" fill="url(#blade)"/>'
                '<path d="M170 308 V436" stroke="#B9C3D2" stroke-width="1.6"/>'
                '<rect x="144" y="296" width="52" height="10" rx="5" fill="url(#gold)"/>'
                '<rect x="165" y="262" width="10" height="34" rx="3" fill="#3A1A12"/>'
                '<path d="M165 270 H175 M165 278 H175 M165 286 H175" stroke="#5A2C1E" stroke-width="2"/>'
                '<circle cx="170" cy="256" r="7.5" fill="url(#gold)"/>'
                '<circle cx="170" cy="301" r="3" fill="#C2283F"/>')
    body.append(f'<g filter="url(#shadow)"><text x="170" y="80" text-anchor="middle" font-family="{CAPS}" '
                f'font-weight="700" font-size="48" letter-spacing="8" fill="url(#gold)">IRONVEIL</text></g>')
    body.append('<g stroke="url(#gold)" stroke-width="1.4"><path d="M58 98 H150 M190 98 H282"/></g>'
                '<path d="M170 92 L176 98 L170 104 L164 98 Z" fill="url(#gold)"/>')
    return svg("Ironveil", defs, "\n".join(body))


def orbit_garden() -> str:
    rng = random.Random(53)
    cx, cy, r = 170, 650, 335
    defs = (linear("sky", (0, "#120E3A"), (.45, "#3A2A86"), (.78, "#B25BA4"), (1, "#F49CB9"))
            + radial("planet", (0, "#FFE0A8"), (.6, "#FFB48C"), (1, "#E27093"), cy=.08, r=.7)
            + radial("ringed", (0, "#C8F7FF"), (1, "#3FA9E0"), cx=.35, cy=.3, r=.8)
            + radial("small", (0, "#E6FFD6"), (1, "#7FD88A"), cx=.35, cy=.3, r=.8)
            + linear("title", (0, "#FFFFFF"), (1, "#FFE0F0"))
            + SHADOW)
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>', stars(rng, 50, 6, 330)]
    for _ in range(9):
        body.append(sparkle(rng.uniform(16, W - 16), rng.uniform(120, 330), rng.uniform(3, 7.5), rng.uniform(.55, .95)))
    body.append('<ellipse cx="170" cy="250" rx="152" ry="44" transform="rotate(-12 170 250)" fill="none" '
                'stroke="#FFFFFF" stroke-opacity=".35" stroke-width="1.5" stroke-dasharray="2 7" stroke-linecap="round"/>')
    body.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#planet)"/>')
    body.append(f'<g fill="none"><circle cx="{cx}" cy="{cy}" r="{r - 34}" stroke="#FFFFFF" stroke-opacity=".12" stroke-width="12"/>'
                f'<circle cx="{cx}" cy="{cy}" r="{r - 82}" stroke="#E27093" stroke-opacity=".2" stroke-width="22"/>'
                f'<circle cx="{cx}" cy="{cy}" r="{r - 140}" stroke="#FFFFFF" stroke-opacity=".1" stroke-width="16"/></g>')
    body.append('<ellipse cx="112" cy="432" rx="30" ry="10" fill="#8FD9FF"/>'
                '<ellipse cx="104" cy="429" rx="12" ry="3" fill="#FFFFFF" opacity=".55"/>'
                '<ellipse cx="238" cy="468" rx="22" ry="7" fill="#8FD9FF" opacity=".85"/>')
    flowers = []
    for _ in range(46):
        x, y = rng.uniform(20, W - 20), rng.uniform(352, 492)
        if math.hypot(x - cx, y - cy) > r - 14:
            continue
        color = rng.choice(("#FFFFFF", "#FF6F9F", "#FFE36E", "#FFFFFF"))
        flowers.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{rng.choice((1.6, 2.2, 2.8))}" fill="{color}" opacity="{rng.uniform(.7, 1):.2f}"/>')
    body.append("".join(flowers))
    trees = []
    for i, angle in enumerate((-.5, -.41, -.3, -.2, -.07, .05, .27, .38, .48)):
        x = cx + r * math.sin(angle)
        y = cy - r * math.cos(angle)
        size = (1.2, .9, 1.05, .8, 1.15, .85, 1, .8, 1.1)[i]
        crown = "#3FBF7F" if i % 2 else "#2E9E6B"
        trees.append(f'<g transform="translate({f(x)} {f(y)}) rotate({f(math.degrees(angle))}) scale({size})">'
                     f'<rect x="-2" y="-14" width="4" height="15" rx="1.5" fill="#8A4B57"/>'
                     f'<circle cx="0" cy="-20" r="11" fill="{crown}"/><circle cx="-4" cy="-24" r="4" fill="#FFFFFF" opacity=".22"/></g>')
    body.append("".join(trees))
    angle = .16
    hx, hy = cx + r * math.sin(angle), cy - r * math.cos(angle)
    body.append(f'<g transform="translate({f(hx)} {f(hy)}) rotate({f(math.degrees(angle))})">'
                '<rect x="-12" y="-18" width="24" height="18" rx="2" fill="#FFF6EE"/>'
                '<path d="M-16 -17 L0 -32 L16 -17 Z" fill="#E2556E"/>'
                '<rect x="-4" y="-10" width="8" height="10" rx="1.5" fill="#8A4B57"/>'
                '<rect x="5" y="-14" width="5" height="5" rx="1" fill="#FFD27A"/></g>')
    body.append('<ellipse cx="252" cy="196" rx="54" ry="13" transform="rotate(-18 252 196)" fill="none" '
                'stroke="#FFFFFF" stroke-opacity=".75" stroke-width="3"/>'
                '<circle cx="252" cy="196" r="30" fill="url(#ringed)"/>'
                '<path d="M199.5 211.6 A54 13 -18 0 0 304.5 180.4" transform="rotate(0)" fill="none" '
                'stroke="#FFFFFF" stroke-opacity=".9" stroke-width="3" stroke-linecap="round"/>')
    body.append('<circle cx="88" cy="276" r="20" fill="url(#small)"/>'
                '<rect x="86" y="244" width="4" height="13" rx="1.5" fill="#8A4B57"/>'
                '<circle cx="88" cy="242" r="8" fill="#2E9E6B"/>'
                '<circle cx="74" cy="154" r="9" fill="#FFF1C7"/><circle cx="71" cy="151" r="2.4" fill="#E9D49A"/>')
    body.append(f'<g filter="url(#shadow)" text-anchor="middle" font-family="{ROUNDED}" font-weight="800">'
                f'<text x="170" y="74" font-size="46" fill="url(#title)">Orbit</text>'
                f'<text x="170" y="116" font-size="38" letter-spacing="3" fill="#FFD49A">GARDEN</text></g>')
    return svg("Orbit Garden", defs, "\n".join(body))


def paper_peaks() -> str:
    defs = (linear("sky", (0, "#D6F1FF"), (.62, "#9ED2F7"), (1, "#86C3F0"))
            + linear("trail", (0, "#FFFFFF", 0), (1, "#FFFFFF", .95), x2=1, y2=0)
            + '<filter id="paper" x="-10%" y="-10%" width="120%" height="130%">'
              '<feDropShadow dx="0" dy="3" stdDeviation="2" flood-color="#1D3B6B" flood-opacity=".25"/></filter>')
    body = [f'<rect width="{W}" height="{H}" fill="url(#sky)"/>',
            '<circle cx="266" cy="150" r="46" fill="#FFF0B3" opacity=".7"/>',
            '<circle cx="266" cy="150" r="33" fill="#FFE07A"/>']

    def cloud(x: float, y: float, s: float) -> str:
        return (f'<g transform="translate({x} {y}) scale({s})" filter="url(#paper)">'
                '<path d="M0 20 C0 10 8 4 18 6 C22 -4 36 -6 44 2 C52 -2 64 4 64 14 C72 14 76 20 76 24 '
                'C76 28 72 30 68 30 L6 30 C2 30 0 26 0 20 Z" fill="#FFFFFF"/>'
                '<path d="M6 30 L68 30" stroke="#D4E8F7" stroke-width="2"/></g>')
    body += [cloud(30, 168, .9), cloud(196, 222, .7), cloud(96, 236, .5)]

    def peak(left: float, apex: tuple, right: float, base: float, light: str, dark: str, snow: bool) -> str:
        ax, ay = apex
        out = (f'<path d="M{left} {base} L{ax} {ay} L{ax} {base} Z" fill="{light}"/>'
               f'<path d="M{ax} {ay} L{right} {base} L{ax} {base} Z" fill="{dark}"/>')
        if snow:
            t = .26
            lx, ly = ax + (left - ax) * t, ay + (base - ay) * t
            rx, ry = ax + (right - ax) * t, ay + (base - ay) * t
            out += (f'<path d="M{ax} {ay} L{f(lx)} {f(ly)} L{f(ax - 6)} {f(ly - 6)} L{ax} {f(ly + 4)} Z" fill="#FFFFFF"/>'
                    f'<path d="M{ax} {ay} L{f(rx)} {f(ry)} L{f(ax + 7)} {f(ry - 5)} L{ax} {f(ly + 4)} Z" fill="#E3EEF8"/>')
        return out

    body.append(f'<g filter="url(#paper)">{peak(126, (226, 160), 330, 344, "#B4D9F4", "#86B8E4", True)}</g>')
    body.append(f'<g filter="url(#paper)">{peak(26, (118, 196), 214, 344, "#98C6EC", "#6FA6DA", True)}</g>')
    body.append(f'<g filter="url(#paper)">{peak(-34, (66, 262), 170, 372, "#6FA9DC", "#4F87C3", False)}'
                f'{peak(184, (288, 248), 384, 372, "#7DB5E2", "#5A92CC", False)}</g>')
    body.append('<path d="M0 360 C70 342 140 372 210 356 S300 344 340 352 L340 500 L0 500 Z" fill="#8ED48A" filter="url(#paper)"/>'
                '<path d="M0 400 C80 384 150 410 230 394 S310 384 340 392 L340 500 L0 500 Z" fill="#6DBF6E" filter="url(#paper)"/>'
                '<path d="M0 446 C90 432 170 456 250 440 S320 432 340 438 L340 500 L0 500 Z" fill="#4FA65A" filter="url(#paper)"/>')
    body.append('<path d="M150 500 C140 470 196 452 206 432" fill="none" stroke="#F6EBCF" stroke-width="10" stroke-linecap="round"/>')
    firs = []
    for x, y, s in ((34, 404, 1), (58, 398, .8), (274, 392, .9), (300, 398, 1.1), (322, 404, .7), (96, 452, .9), (122, 458, .7), (262, 456, .8)):
        firs.append(f'<g transform="translate({x} {y}) scale({s})">'
                    '<path d="M0 -30 L-11 0 L0 0 Z" fill="#4CAF63"/><path d="M0 -30 L11 0 L0 0 Z" fill="#3A8F51"/>'
                    '<rect x="-1.5" y="0" width="3" height="5" fill="#8A6A4F"/></g>')
    body.append(f'<g filter="url(#paper)">{"".join(firs)}</g>')
    body.append('<g transform="translate(206 432)" filter="url(#paper)">'
                '<rect x="-15" y="-18" width="30" height="18" fill="#FFF6EA"/>'
                '<path d="M-19 -17 L0 -36 L0 -17 Z" fill="#E2556E"/><path d="M0 -36 L19 -17 L0 -17 Z" fill="#C43C57"/>'
                '<rect x="-4" y="-10" width="8" height="10" fill="#8A6A4F"/>'
                '<rect x="7" y="-14" width="5" height="5" fill="#9ED2F7"/></g>')
    body.append('<path d="M40 330 C90 300 120 262 168 250 S226 234 238 214" fill="none" stroke="#FFFFFF" '
                'stroke-width="2.2" stroke-dasharray="6 7" stroke-linecap="round" opacity=".9"/>')
    body.append('<g transform="translate(236 214) rotate(-24)" filter="url(#paper)">'
                '<path d="M0 0 L54 -10 L10 10 Z" fill="#FFFFFF"/>'
                '<path d="M10 10 L54 -10 L20 16 Z" fill="#DCE8F3"/>'
                '<path d="M10 10 L54 -10 L14 4 Z" fill="#F0F6FB"/></g>')
    body.append(f'<g text-anchor="middle" font-family="{ROUNDED}" font-weight="900" font-size="47">'
                f'<text x="172" y="88" fill="#FFFFFF">Paper Peaks</text>'
                f'<text x="170" y="86" fill="#1C2C5E">Paper Peaks</text></g>')
    return svg("Paper Peaks", defs, "\n".join(body))


COVERS = {
    "aurora-rally": aurora_rally,
    "lanterne": lanterne,
    "mosslight": mosslight,
    "ironveil": ironveil,
    "orbit-garden": orbit_garden,
    "paper-peaks": paper_peaks,
}


def main() -> None:
    for name, draw in COVERS.items():
        path = OUT / f"{name}.svg"
        path.write_text(draw())
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
