"""When capture.sh keeps the screen of a scenario.

The gallery says when its screen has settled (tmp/ready-<scenario>.json), but
the simulator can still be showing iOS opening it: the gallery's white launch
screen, or that screen fading into the gallery. On Ad's Mac, loaded by a
build beside the screenshots, the iPhone Duo simulator's screens came out
white or washed out with white: 4 of 5 for #175 and 1 of 5 for #161 on 14
November, then 7 of 11 for #163 (run 43545961457, load 15 to 17), when
GitHub's Macs took the same screens clean.

So capture.sh takes the screen again, a moment apart, until it is drawn, its
middle not one flat colour, and the same as the time before: the fading
changes the whole screen from one screenshot to the next, where a spinner
turns in a few cells. screenshot.swift prints each screen's signature: the
screen cut into cells, row by row, with each cell's mean luminance (0 to 255)
and the spread of luminance in it.
"""

from __future__ import annotations

import time

# A cell has changed when its mean luminance has moved by more than this.
MOVED = 2.0
# Two screens are the same when no more than this share of their cells has
# changed.
SAME = 0.05
# How long capture.sh takes the screen again, and the pause between two.
SECONDS = 60
PAUSE = 0.5

BLANK = "blank"


def middle(signature: dict) -> list[int]:
    """The cells of the middle half of the screen, across and down."""
    columns, rows = signature["columns"], signature["rows"]
    return [row * columns + column
            for row in range(rows // 4, rows - rows // 4)
            for column in range(columns // 4, columns - columns // 4)]


def blank(signature: dict) -> bool:
    """The middle of the screen is one flat colour: nothing drawn on it yet,
    as on the gallery's white launch screen."""
    cells = middle(signature)
    means = [signature["means"][cell] for cell in cells]
    return all(signature["spreads"][cell] <= 1 for cell in cells) and max(means) - min(means) <= 1


def changed(before: dict, after: dict) -> float:
    """The share of the cells whose mean luminance moved from BEFORE to
    AFTER: all of them when the screens are not cut alike."""
    if (before["columns"], before["rows"]) != (after["columns"], after["rows"]):
        return 1.0
    moved = sum(1 for was, now in zip(before["means"], after["means"]) if abs(was - now) > MOVED)
    return moved / len(after["means"])


def settle(shoot, seconds: float = SECONDS, pause: float = PAUSE, sleep=time.sleep, now=time.monotonic):
    """Takes the screen with SHOOT, which keeps it and returns its signature,
    until it is drawn and the same as the time before. Returns how many
    screenshots that took, and None; or, once SECONDS have run out, what was
    wrong with the last one: BLANK, or how much of it still changed."""
    deadline = now() + seconds
    before = shoot()
    shots = 1
    while True:
        sleep(pause)
        after = shoot()
        shots += 1
        if not blank(after) and changed(before, after) <= SAME:
            return shots, None
        if now() >= deadline:
            if blank(after):
                return shots, BLANK
            return shots, f"still changing ({changed(before, after):.0%} of it)"
        before = after
