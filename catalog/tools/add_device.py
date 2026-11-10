#!/usr/bin/env python3
"""Adds a tester's iPhone to catalog/devices.json from a Cartouche report.

System › Report a problem in Cartouche puts this iPhone's memory limit in its
report as an entry of devices.json, on the line after "For
catalog/devices.json:". The report may be the text a tester sent, or the
GitHub issue the bug report form made of it. This reads that entry, checks it
as devices.schema.json would, and adds it to devices.json: a model the file
does not have yet, with its chip, which iOS does not say (--chip, from the
model's Apple specifications, unless the report has it); or a new
measurement of one it has. A measurement the file already holds is not added
again, and the file keeps the way it is written.

The entry holds nothing personal: a model identifier, iOS's version, a date
and what Cartouche measured.

usage: add_device.py REPORT [--chip CHIP] [--devices FILE] [--dry-run]
       REPORT is a file, or - for the standard input
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEVICES = Path(__file__).resolve().parents[1] / "devices.json"
MARKER = "For catalog/devices.json:"

IDENTIFIER = re.compile(r"^(iPhone|iPad)[0-9]+,[0-9]+$")
DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
IOS = re.compile(r"^[0-9]+(\.[0-9]+){0,2}$")
DEVICE_KEYS = ("identifier", "chip", "memoryGB", "measurements")
MEASUREMENT_KEYS = ("date", "iOS", "increasedMemoryLimit", "appMemoryLimitMiB")


class ReportError(Exception):
    """The report holds no entry, or one devices.json cannot take."""


def read_entry(text: str) -> dict:
    """The devices.json entry of a report, checked."""
    start = text.find(MARKER)
    start = text.find("{", start + len(MARKER)) if start >= 0 else text.find('{"identifier"')
    if start < 0:
        raise ReportError(f'no "{MARKER}" line with an entry after it in the report')
    try:
        entry, _ = json.JSONDecoder().raw_decode(text, start)
    except json.JSONDecodeError as error:
        raise ReportError(f"the entry after {MARKER!r} is not JSON: {error}") from None
    check_entry(entry)
    return entry


def is_integer(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def check_entry(entry) -> None:
    """Refuses what devices.schema.json refuses; the chip may be missing."""
    if not isinstance(entry, dict):
        raise ReportError("the entry is not an object")
    unknown = set(entry) - set(DEVICE_KEYS)
    if unknown:
        raise ReportError(f"the entry has keys devices.json does not: {', '.join(sorted(unknown))}")
    identifier = entry.get("identifier")
    if not isinstance(identifier, str) or not IDENTIFIER.match(identifier):
        raise ReportError(f"not a model identifier: {identifier!r}")
    if "chip" in entry:
        check_chip(entry["chip"])
    if not is_integer(entry.get("memoryGB")) or entry["memoryGB"] < 1:
        raise ReportError(f"not a memory size in GB: {entry.get('memoryGB')!r}")
    measurements = entry.get("measurements")
    if not isinstance(measurements, list) or not measurements:
        raise ReportError("the entry has no measurement")
    for measurement in measurements:
        if not isinstance(measurement, dict) or set(measurement) != set(MEASUREMENT_KEYS):
            raise ReportError(f"a measurement needs exactly {', '.join(MEASUREMENT_KEYS)}: {measurement!r}")
        if not isinstance(measurement["date"], str) or not DATE.match(measurement["date"]):
            raise ReportError(f"not a date: {measurement['date']!r}")
        if not isinstance(measurement["iOS"], str) or not IOS.match(measurement["iOS"]):
            raise ReportError(f"not an iOS version: {measurement['iOS']!r}")
        if not isinstance(measurement["increasedMemoryLimit"], bool):
            raise ReportError(f"increasedMemoryLimit is not true or false: {measurement['increasedMemoryLimit']!r}")
        if not is_integer(measurement["appMemoryLimitMiB"]) or measurement["appMemoryLimitMiB"] < 1:
            raise ReportError(f"not a memory limit in MiB: {measurement['appMemoryLimitMiB']!r}")


def check_chip(chip) -> None:
    if not isinstance(chip, str) or not 2 <= len(chip) <= 20:
        raise ReportError(f"not a chip name of 2 to 20 characters: {chip!r}")


def model_order(identifier: str) -> tuple:
    family, major, minor = re.match(r"^([A-Za-z]+)([0-9]+),([0-9]+)$", identifier).groups()
    return family, int(major), int(minor)


def measurement_order(measurement: dict) -> tuple:
    version = tuple(int(part) for part in measurement["iOS"].split("."))
    return measurement["date"], version, measurement["increasedMemoryLimit"], measurement["appMemoryLimitMiB"]


def add(devices: dict, entry: dict, chip: str | None = None) -> list[str]:
    """Adds ENTRY to DEVICES, as devices.json holds them; says what changed,
    or nothing when the file already had it all."""
    if chip is not None:
        check_chip(chip)
    said = []
    device = next((d for d in devices["devices"] if d["identifier"] == entry["identifier"]), None)
    if device is None:
        chip = chip or entry.get("chip")
        if not chip:
            raise ReportError(f"{entry['identifier']} is not in devices.json yet: give its chip with --chip, "
                              "from the model's Apple specifications")
        device = {"identifier": entry["identifier"], "chip": chip, "memoryGB": entry["memoryGB"], "measurements": []}
        devices["devices"].append(device)
        devices["devices"].sort(key=lambda d: model_order(d["identifier"]))
        said.append(f"{device['identifier']}: new, {chip}, {device['memoryGB']} GB")
    else:
        for key, value in (("chip", chip or entry.get("chip")), ("memoryGB", entry["memoryGB"])):
            if value is not None and value != device[key]:
                raise ReportError(f"{device['identifier']}: devices.json says {key} {device[key]!r}, "
                                  f"the report {value!r}")
    for measurement in entry["measurements"]:
        measurement = {key: measurement[key] for key in MEASUREMENT_KEYS}
        if measurement in device["measurements"]:
            continue
        device["measurements"].append(measurement)
        said.append(f"{device['identifier']}: {measurement['date']}, iOS {measurement['iOS']}, "
                    f"Increased Memory Limit {'on' if measurement['increasedMemoryLimit'] else 'off'}, "
                    f"{measurement['appMemoryLimitMiB']} MiB")
    device["measurements"].sort(key=measurement_order)
    return said


def dump(devices: dict) -> str:
    """devices.json as it is written: one line for each measurement."""
    def value(item) -> str:
        return json.dumps(item, ensure_ascii=False)

    lines = ["{", f'  "schema": {value(devices["schema"])},', '  "devices": [']
    for index, device in enumerate(devices["devices"]):
        lines += [
            "    {",
            f'      "identifier": {value(device["identifier"])},',
            f'      "chip": {value(device["chip"])},',
            f'      "memoryGB": {value(device["memoryGB"])},',
            '      "measurements": [',
        ]
        rows = ["        { " + ", ".join(f"{value(key)}: {value(measurement[key])}" for key in MEASUREMENT_KEYS) + " }"
                for measurement in device["measurements"]]
        lines.append(",\n".join(rows))
        lines += ["      ]", "    }" + ("," if index < len(devices["devices"]) - 1 else "")]
    lines += ["  ]", "}"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("report", help="the report, or - for the standard input")
    parser.add_argument("--chip", help="the chip of a model devices.json does not have yet, such as A19 Pro")
    parser.add_argument("--devices", type=Path, default=DEVICES, help="the devices.json to add to")
    parser.add_argument("--dry-run", action="store_true", help="say what would be added, write nothing")
    args = parser.parse_args(argv)

    text = sys.stdin.read() if args.report == "-" else Path(args.report).read_text(encoding="utf-8")
    devices = json.loads(args.devices.read_text(encoding="utf-8"))
    try:
        said = add(devices, read_entry(text), args.chip)
    except ReportError as error:
        print(f"add_device.py: {error}", file=sys.stderr)
        return 2
    if not said:
        print(f"{args.devices} already has this measurement")
        return 0
    for line in said:
        print(("would add " if args.dry_run else "added ") + line)
    if not args.dry_run:
        args.devices.write_text(dump(devices), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
