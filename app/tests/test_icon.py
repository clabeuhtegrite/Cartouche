"""Checks Cartouche's icon sets in app/icon, which prepare.sh puts in place of
LiveContainer's.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import struct
import unittest
from pathlib import Path

ICON = Path(__file__).resolve().parents[2] / "app" / "icon"
SETS = ("AppIcon.appiconset", "AppIconGrey.appiconset")
# PNG colour types: 2 is RGB, 6 is RGB with alpha.
RGB, RGBA = 2, 6


def png_header(path: Path) -> tuple[int, int, int]:
    """Width, height and colour type, from the PNG's IHDR chunk."""
    data = path.read_bytes()[:29]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    return width, height, data[25]


class IconTest(unittest.TestCase):
    def test_each_set_has_a_light_dark_and_tinted_icon_at_1024(self):
        for name in SETS:
            with self.subTest(set=name):
                images = json.loads((ICON / name / "Contents.json").read_text())["images"]
                appearances = {}
                for image in images:
                    looks = [a["value"] for a in image.get("appearances", [])] or ["light"]
                    appearances[looks[0]] = image["filename"]
                    self.assertEqual(image["size"], "1024x1024")
                    width, height, _ = png_header(ICON / name / image["filename"])
                    self.assertEqual((width, height), (1024, 1024))
                self.assertEqual(sorted(appearances), ["dark", "light", "tinted"])
                # iOS refuses an alpha channel in the light icon; dark and
                # tinted ones are transparent where iOS draws its background.
                self.assertEqual(png_header(ICON / name / appearances["light"])[2], RGB)
                self.assertEqual(png_header(ICON / name / appearances["dark"])[2], RGBA)
                self.assertEqual(png_header(ICON / name / appearances["tinted"])[2], RGBA)
                listed = {image["filename"] for image in images}
                present = {p.name for p in (ICON / name).glob("*.png")}
                self.assertEqual(present, listed, "every PNG in the set is listed, and only those")

    def test_the_grey_icons_of_an_extra_copy(self):
        for name, size in (("AppIconGrey60x60@2x.png", 120), ("AppIconGrey76x76@2x~ipad.png", 152)):
            with self.subTest(icon=name):
                width, height, _ = png_header(ICON / name)
                self.assertEqual((width, height), (size, size))


if __name__ == "__main__":
    unittest.main()
