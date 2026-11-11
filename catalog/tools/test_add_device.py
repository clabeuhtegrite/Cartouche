"""add_device.py on reports as Cartouche writes them, and as GitHub's bug
report form shows them."""

import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import add_device

DEVICES = Path(__file__).resolve().parents[1] / "devices.json"

# The line launcher/Tests/CartoucheCoreTests/CartoucheProblemReportTests.swift
# expects of CartoucheDeviceMeasurement.json.
KNOWN = ('{"identifier": "iPhone19,4", "chip": "A20 Pro", "memoryGB": 12, "measurements": '
         '[{"date": "2026-11-10", "iOS": "27.3", "increasedMemoryLimit": true, "appMemoryLimitMiB": 6143}]}')
NEW = ('{"identifier": "iPhone18,1", "memoryGB": 12, "measurements": '
       '[{"date": "2026-11-12", "iOS": "27.3.1", "increasedMemoryLimit": true, "appMemoryLimitMiB": 6143}]}')


def report(entry: str) -> str:
    return f"""What happened
(nothing written)

Problem report, 2026-11-12 18:03 UTC
Cartouche 0.10.0 (1a2b3c4)

For catalog/devices.json:
{entry}

Last errors, newest first:
Installing Celeste
The network connection was lost.
"""


def issue(entry: str) -> str:
    return f"""### What happened

Nouvel iPhone.

### iPhone or iPad model

iPhone18,1

### Logs

```text
Problem report, 2026-11-12 18:03 UTC
For catalog/devices.json:
{entry}
```

### Rules

- [X] This report contains no game files, keys, firmware or links to them.
"""


class AddDeviceTest(unittest.TestCase):
    def setUp(self):
        self.devices = json.loads(DEVICES.read_text(encoding="utf-8"))

    def test_reads_the_entry_of_a_report_and_of_an_issue(self):
        self.assertEqual(add_device.read_entry(report(KNOWN)), json.loads(KNOWN))
        self.assertEqual(add_device.read_entry(issue(NEW)), json.loads(NEW))
        # An entry pasted without the line before it.
        self.assertEqual(add_device.read_entry("Here it is: " + NEW + " thanks"), json.loads(NEW))

    def test_refuses_what_devices_json_would(self):
        entry = json.loads(KNOWN)
        bad = {
            "no entry": "What happened\nNothing.\n",
            "not JSON": report('{"identifier": "iPhone19,4", '),
            "a simulator": report(json.dumps({**entry, "identifier": "arm64"})),
            "an unknown key": report(json.dumps({**entry, "name": "Ad's iPhone"})),
            "no measurement": report(json.dumps({**entry, "measurements": []})),
            "a memory size as text": report(json.dumps({**entry, "memoryGB": "12"})),
            "a short chip": report(json.dumps({**entry, "chip": "A"})),
        }
        measurement = entry["measurements"][0]
        for name, change in {
            "a date with a time": {"date": "2026-11-10T07:12"},
            "a beta's name": {"iOS": "27.3 beta 2"},
            "a limit as true": {"appMemoryLimitMiB": True},
            "a capability as 1": {"increasedMemoryLimit": 1},
        }.items():
            bad[name] = report(json.dumps({**entry, "measurements": [{**measurement, **change}]}))
        bad["a measurement with a key more"] = report(json.dumps({**entry, "measurements": [{**measurement, "peak": 1}]}))
        for name, text in bad.items():
            with self.subTest(name), self.assertRaises(add_device.ReportError):
                add_device.read_entry(text)

    def test_adds_a_measurement_of_a_known_model(self):
        said = add_device.add(self.devices, add_device.read_entry(report(KNOWN)))
        self.assertEqual(said, ["iPhone19,4: 2026-11-10, iOS 27.3, Increased Memory Limit on, 6143 MiB"])
        measurements = self.devices["devices"][0]["measurements"]
        self.assertIn({"date": "2026-11-10", "iOS": "27.3", "increasedMemoryLimit": True, "appMemoryLimitMiB": 6143},
                      measurements)
        # In order of date, then of iOS version, as the file keeps them.
        self.assertEqual(measurements, sorted(measurements, key=add_device.measurement_order))
        # The same report again adds nothing.
        self.assertEqual(add_device.add(self.devices, add_device.read_entry(report(KNOWN))), [])

    def test_a_new_model_needs_its_chip(self):
        entry = add_device.read_entry(report(NEW))
        before = copy.deepcopy(self.devices)
        with self.assertRaisesRegex(add_device.ReportError, "--chip"):
            add_device.add(self.devices, entry)
        self.assertEqual(self.devices, before)
        said = add_device.add(self.devices, entry, chip="A19 Pro")
        self.assertEqual(said[0], "iPhone18,1: new, A19 Pro, 12 GB")
        self.assertEqual([d["identifier"] for d in self.devices["devices"]], ["iPhone18,1", "iPhone19,4"])
        self.assertEqual(self.devices["devices"][0]["chip"], "A19 Pro")

    def test_models_sort_by_number(self):
        models = sorted(["iPhone19,10", "iPhone9,1", "iPhone19,4"], key=add_device.model_order)
        self.assertEqual(models, ["iPhone9,1", "iPhone19,4", "iPhone19,10"])

    def test_a_report_that_disagrees_with_the_file_is_refused(self):
        entry = add_device.read_entry(report(KNOWN))
        with self.assertRaisesRegex(add_device.ReportError, "chip"):
            add_device.add(self.devices, entry, chip="A19 Pro")
        with self.assertRaisesRegex(add_device.ReportError, "memoryGB"):
            add_device.add(self.devices, {**entry, "memoryGB": 8})

    def test_keeps_the_file_as_it_is_written(self):
        self.assertEqual(add_device.dump(self.devices), DEVICES.read_text(encoding="utf-8"))
        add_device.add(self.devices, add_device.read_entry(report(NEW)), chip="A19 Pro")
        self.assertEqual(json.loads(add_device.dump(self.devices)), self.devices)

    def test_main_writes_devices_json(self):
        with tempfile.TemporaryDirectory() as folder:
            devices = Path(folder) / "devices.json"
            devices.write_text(DEVICES.read_text(encoding="utf-8"), encoding="utf-8")
            sent = Path(folder) / "report.txt"
            sent.write_text(issue(NEW), encoding="utf-8")

            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                self.assertEqual(add_device.main([str(sent), "--devices", str(devices)]), 2)
            self.assertIn("--chip", err.getvalue())
            self.assertEqual(devices.read_text(encoding="utf-8"), DEVICES.read_text(encoding="utf-8"))

            with redirect_stdout(out):
                self.assertEqual(add_device.main([str(sent), "--devices", str(devices), "--chip", "A19 Pro", "--dry-run"]), 0)
            self.assertEqual(devices.read_text(encoding="utf-8"), DEVICES.read_text(encoding="utf-8"))

            with redirect_stdout(out):
                self.assertEqual(add_device.main([str(sent), "--devices", str(devices), "--chip", "A19 Pro"]), 0)
            written = json.loads(devices.read_text(encoding="utf-8"))
            self.assertEqual(written["devices"][0]["identifier"], "iPhone18,1")
            self.assertIn("added iPhone18,1: new, A19 Pro, 12 GB", out.getvalue())

            with redirect_stdout(out):
                self.assertEqual(add_device.main([str(sent), "--devices", str(devices)]), 0)
            self.assertIn("already has this measurement", out.getvalue())


if __name__ == "__main__":
    unittest.main()
