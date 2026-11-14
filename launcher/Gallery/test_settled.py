"""settled.py: capture.sh keeps a scenario's screen once the simulator shows
it drawn and still, not iOS still opening the gallery (run 43545961457).

    python3 -m unittest discover -s launcher/Gallery -p 'test_*.py'
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import settled  # noqa: E402

# The signatures of real screenshots, computed as screenshot.swift does: the
# gallery's white launch screen, and that screen fading into the gallery, as
# Ad's Mac kept them, and a screen drawn, as GitHub's Mac kept it
# (test_settled.json says which).
SCREENS = json.loads((HERE / "test_settled.json").read_text())
WHITE, FADING, DRAWN = SCREENS["white"], SCREENS["fading"], SCREENS["drawn"]


def veiled(signature, white):
    """SIGNATURE under a veil of white, from 0 to 1: the screen as iOS fades
    the launch screen out over it."""
    return dict(signature, means=[white * 255 + (1 - white) * mean for mean in signature["means"]],
                spreads=[round((1 - white) * spread) for spread in signature["spreads"]])


class Clock:
    def __init__(self):
        self.time = 0.0

    def now(self):
        return self.time

    def sleep(self, seconds):
        self.time += seconds


class Simulator:
    """A screen showing SCREENS one after the other, the last one staying."""

    def __init__(self, *screens):
        self.screens = screens
        self.shots = 0
        self.kept = None

    def shoot(self):
        self.kept = self.screens[min(self.shots, len(self.screens) - 1)]
        self.shots += 1
        return self.kept


class SettleTests(unittest.TestCase):
    def settle(self, simulator, **options):
        clock = Clock()
        return settled.settle(simulator.shoot, sleep=clock.sleep, now=clock.now, **options)

    def test_waits_for_the_launch_screen_to_fade_into_the_gallery(self):
        # On Ad's Mac, the screenshot taken once the gallery said it had
        # settled was this white, or this washed out (run 43545961457).
        simulator = Simulator(WHITE, WHITE, FADING, veiled(DRAWN, 0.3), veiled(DRAWN, 0.05), DRAWN, DRAWN)
        self.assertEqual(self.settle(simulator), (7, None))
        self.assertIs(simulator.kept, DRAWN)

    def test_a_screen_drawn_already_takes_two_screenshots(self):
        simulator = Simulator(DRAWN)
        self.assertEqual(self.settle(simulator), (2, None))
        self.assertIs(simulator.kept, DRAWN)

    def test_the_white_launch_screen_is_blank_however_still_it_stays(self):
        self.assertTrue(settled.blank(WHITE))
        self.assertFalse(settled.blank(DRAWN))
        shots, problem = self.settle(Simulator(WHITE), seconds=10, pause=1)
        self.assertEqual(problem, settled.BLANK)
        self.assertEqual(shots, 11)

    def test_the_fading_is_drawn_but_not_the_same_as_the_screen_after(self):
        self.assertFalse(settled.blank(FADING))
        self.assertGreater(settled.changed(FADING, DRAWN), 0.9)
        # Its last twentieth still changes most of the screen.
        self.assertGreater(settled.changed(veiled(DRAWN, 0.05), DRAWN), 0.5)
        self.assertEqual(settled.changed(DRAWN, DRAWN), 0)

    def test_a_spinner_turning_does_not_keep_the_screen_from_settling(self):
        turning = dict(DRAWN, means=list(DRAWN["means"]))
        for cell in (119, 120, 135, 136):
            turning["means"][cell] += 40
        self.assertEqual(self.settle(Simulator(DRAWN, turning)), (2, None))

    def test_a_screen_that_keeps_changing_says_how_much(self):
        simulator = Simulator(*[DRAWN, veiled(DRAWN, 0.5)] * 20)
        shots, problem = self.settle(simulator, seconds=10, pause=1)
        self.assertEqual(shots, 11)
        self.assertEqual(problem, "still changing (100% of it)")

    def test_a_screen_cut_otherwise_is_not_the_same(self):
        turned = dict(DRAWN, columns=8, rows=32)
        self.assertEqual(settled.changed(DRAWN, turned), 1.0)


if __name__ == "__main__":
    unittest.main()
