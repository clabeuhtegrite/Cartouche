#!/usr/bin/env python3
"""Cartouche's app icon, a game cartridge, as SVG in each appearance iOS asks for.

    python3 app/icon/make_icon.py        # writes app/icon/svg/*.svg

Each SVG is then rendered at 1024 x 1024, keeping transparency, into the PNGs of
AppIcon.appiconset and AppIconGrey.appiconset (we use Chromium). The light icons
are saved without an alpha channel. app/scripts/prepare.sh copies the icon sets
over LiveContainer's.

- light: the cartridge on Cartouche's colours;
- dark: the cartridge alone, on a transparent background that iOS fills with
  its own dark one;
- tinted: grey levels only, which iOS turns into the tint the player picked;
- grey and grey-dark: the light and dark icons in grey, for an extra copy of
  Cartouche installed from its settings, as LiveContainer does with its own
  grey icon;
- mac: the light icon on macOS's grid, a rounded square of 824 in the 1024
  canvas with its shadow, for Cartouche Builder (builder/mac/bundle.sh makes
  its .icns from the PNG, builder/mac/Resources/AppIcon1024.png).
"""

from pathlib import Path

W = 1024
BX, BY, BW, BH, BR = 247, 152, 530, 720, 64                  # cartridge body
LX, LY, LW, LH, LR = BX + 50, BY + 158, BW - 100, 344, 38   # label
SX, SW, SH = BX + 72, BW - 144, 104                         # contacts, open at the bottom
SY = BY + BH - SH

BRAND = ("#4F46E5", "#EC4899")
MAC_SIDE, MAC_RADIUS = 824, 185  # macOS's icon grid, in the 1024 canvas
GREY = ("#8E8E93", "#48484A")


def body_path() -> str:
    r = BR
    return (f"M{BX + r} {BY} h{BW - 2 * r} a{r} {r} 0 0 1 {r} {r} v{BH - 2 * r} "
            f"a{r} {r} 0 0 1 -{r} {r} h-{BW - 2 * r} a{r} {r} 0 0 1 -{r} -{r} "
            f"v-{BH - 2 * r} a{r} {r} 0 0 1 {r} -{r} z")


def slot_path() -> str:
    r = 22
    bottom = BY + BH + 40
    return (f"M{SX} {bottom} V{SY + r} a{r} {r} 0 0 1 {r} -{r} h{SW - 2 * r} "
            f"a{r} {r} 0 0 1 {r} {r} V{bottom} z")


def contacts(fill: str) -> str:
    count, gap = 7, 14
    width = (SW - 44 - gap * (count - 1)) / count
    return "".join(
        f'<rect x="{SX + 22 + i * (width + gap):.1f}" y="{SY + 18}" width="{width:.1f}" '
        f'height="{SH}" rx="6" fill="{fill}"/>'
        for i in range(count))


def ridges(fill: str) -> str:
    return "".join(
        f'<rect x="{BX + 135}" y="{BY + 50 + i * 34}" width="{BW - 270}" height="14" rx="7" fill="{fill}"/>'
        for i in range(3))


def controls(fill: str) -> str:
    """A cross-shaped pad and two buttons, on the label."""
    cy = LY + LH / 2
    x, arm, half = LX + 122, 74, 21
    return (f'<g fill="{fill}">'
            f'<rect x="{x - arm}" y="{cy - half}" width="{2 * arm}" height="{2 * half}" rx="11"/>'
            f'<rect x="{x - half}" y="{cy - arm}" width="{2 * half}" height="{2 * arm}" rx="11"/>'
            f'<circle cx="{LX + LW - 152}" cy="{cy + 32}" r="32"/>'
            f'<circle cx="{LX + LW - 80}" cy="{cy - 32}" r="32"/>'
            f'</g>')


def gradient(name: str, colors: tuple[str, str]) -> str:
    return (f'<linearGradient id="{name}" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="{colors[0]}"/><stop offset="1" stop-color="{colors[1]}"/>'
            f'</linearGradient>')


def opaque(colors: tuple[str, str]) -> tuple[str, list[str]]:
    defs = (gradient("background", colors) + gradient("label", colors) +
            '<radialGradient id="shine" cx="0.2" cy="0.1" r="0.8">'
            '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.25"/>'
            '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>'
            '<linearGradient id="shell" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E9EAF4"/></linearGradient>'
            '<filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">'
            '<feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#1E1B4B" flood-opacity="0.4"/></filter>')
    parts = [f'<rect width="{W}" height="{W}" fill="url(#background)"/>',
             f'<rect width="{W}" height="{W}" fill="url(#shine)"/>',
             f'<path d="{body_path()}" fill="url(#shell)" filter="url(#shadow)"/>',
             ridges("#D3D5E3"),
             f'<rect x="{LX}" y="{LY}" width="{LW}" height="{LH}" rx="{LR}" fill="url(#label)"/>',
             controls("#FFFFFF"),
             f'<g clip-path="url(#body)"><path d="{slot_path()}" fill="#2C2A4A"/>{contacts("url(#gold)")}</g>']
    return defs, parts


def mac() -> str:
    """The light icon in macOS's rounded square: the cartridge scaled into it."""
    o = (W - MAC_SIDE) / 2
    scale = MAC_SIDE / W
    more, parts = opaque(BRAND)
    defs = (f'<clipPath id="body"><path d="{body_path()}"/></clipPath>'
            '<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#FFDB7E"/><stop offset="1" stop-color="#E8A535"/></linearGradient>'
            + more +
            f'<clipPath id="square"><rect x="{o}" y="{o}" width="{MAC_SIDE}" height="{MAC_SIDE}" rx="{MAC_RADIUS}"/></clipPath>'
            '<filter id="drop" x="-20%" y="-20%" width="140%" height="140%">'
            '<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000000" flood-opacity="0.28"/></filter>')
    background, shine, *cartridge = parts
    body = "\n    ".join(cartridge)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">\n'
            f'  <defs>{defs}</defs>\n'
            f'  <rect x="{o}" y="{o}" width="{MAC_SIDE}" height="{MAC_SIDE}" rx="{MAC_RADIUS}" fill="url(#background)" filter="url(#drop)"/>\n'
            f'  <g clip-path="url(#square)">\n    {shine}\n'
            f'    <g transform="translate({o} {o}) scale({scale})">\n    {body}\n    </g>\n  </g>\n</svg>\n')


def svg(variant: str) -> str:
    if variant == "mac":
        return mac()
    defs = (f'<clipPath id="body"><path d="{body_path()}"/></clipPath>'
            '<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#FFDB7E"/><stop offset="1" stop-color="#E8A535"/></linearGradient>')
    if variant == "light":
        more, parts = opaque(BRAND)
        defs += more
    elif variant == "grey":
        more, parts = opaque(GREY)
        defs += more
    elif variant in ("dark", "grey-dark"):
        defs += gradient("brand", BRAND if variant == "dark" else GREY)
        parts = [f'<path d="{body_path()}" fill="url(#brand)"/>',
                 ridges("#1B1838"),
                 f'<rect x="{LX}" y="{LY}" width="{LW}" height="{LH}" rx="{LR}" fill="#16132E"/>',
                 controls("url(#brand)"),
                 f'<g clip-path="url(#body)"><path d="{slot_path()}" fill="#16132E"/>{contacts("url(#gold)")}</g>']
    elif variant == "tinted":
        parts = [f'<path d="{body_path()}" fill="#D9D9D9"/>',
                 ridges("#8C8C8C"),
                 f'<rect x="{LX}" y="{LY}" width="{LW}" height="{LH}" rx="{LR}" fill="#2B2B2B"/>',
                 controls("#FFFFFF"),
                 f'<g clip-path="url(#body)"><path d="{slot_path()}" fill="#2B2B2B"/>{contacts("#BFBFBF")}</g>']
    else:
        raise ValueError(variant)
    body = "\n  ".join(parts)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">\n'
            f'  <defs>{defs}</defs>\n  {body}\n</svg>\n')


def main() -> None:
    out = Path(__file__).resolve().parent / "svg"
    out.mkdir(exist_ok=True)
    for variant in ("light", "dark", "tinted", "grey", "grey-dark", "mac"):
        (out / f"{variant}.svg").write_text(svg(variant))
        print(f"wrote {out / variant}.svg")


if __name__ == "__main__":
    main()
