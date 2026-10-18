"""Tests for the pure logic of the History window, the pill and the hotkey's
double tap (the GTK parts are tested by hand).

Run: python3 -m unittest discover -s tests -v   (or: make check)
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    path = os.path.join(HERE, "..", name)
    module_name = name.replace("-", "_")
    loader = importlib.machinery.SourceFileLoader(module_name, path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(module_name, loader))
    loader.exec_module(module)
    return module


def load_gtk(name):
    """None where PyGObject is missing (macOS): xhisper-history exits then."""
    try:
        return load(name)
    except SystemExit:
        return None


history = load_gtk("xhisper-history")
notify = load("xhisper-notify")  # imports without GTK (falls back to notify-send)
hotkey = load("xhisper-hotkey")
needs_gtk = unittest.skipIf(history is None, "PyGObject (GTK 3) not installed")


@needs_gtk
class Times(unittest.TestCase):
    now = datetime(2026, 10, 18, 15, 0, 0, tzinfo=timezone(timedelta(hours=2)))

    def describe(self, delta):
        stamp = (self.now - delta).strftime("%Y-%m-%dT%H:%M:%S%z")
        return history.describe_time(stamp, now=self.now)

    def test_relative(self):
        self.assertEqual(self.describe(timedelta(seconds=20)), "Just now")
        self.assertEqual(self.describe(timedelta(seconds=-30)), "Just now")  # clock skew
        self.assertEqual(self.describe(timedelta(minutes=12)), "12 min ago")
        self.assertEqual(self.describe(timedelta(hours=2, minutes=59)), "2 h ago")

    def test_calendar(self):
        # astimezone() turns the stamp into local time; compare in that zone.
        local = lambda d: (self.now - d).astimezone()
        when = local(timedelta(hours=7))
        if when.date() == self.now.astimezone().date():
            self.assertEqual(self.describe(timedelta(hours=7)), "Today " + when.strftime("%H:%M"))
        self.assertTrue(self.describe(timedelta(days=1, hours=1)).startswith(("Yesterday ", "Today ")))
        self.assertRegex(self.describe(timedelta(days=3)), r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d\d:\d\d$")
        self.assertRegex(self.describe(timedelta(days=9)), r"^\d\d [A-Z][a-z]{2} \d\d:\d\d$")

    def test_unparsable(self):
        self.assertEqual(history.describe_time("yesterday-ish"), "yesterday-ish")


@needs_gtk
class Lines(unittest.TestCase):
    def test_bullets(self):
        self.assertEqual(history.display_lines("- a\n* b\n\u2022 c\n12. d\nplain"),
                         [("\u2022", "a"), ("\u2022", "b"), ("\u2022", "c"), ("12.", "d"), (None, "plain")])

    def test_not_bullets(self):
        self.assertEqual(history.display_lines("-a\n1.5 kg"), [(None, "-a"), (None, "1.5 kg")])

    def test_rtl(self):
        self.assertTrue(history.is_rtl("مرحبا world"))
        self.assertTrue(history.is_rtl("12, שלום"))
        self.assertFalse(history.is_rtl("hello مرحبا"))
        self.assertFalse(history.is_rtl("123 !"))


@needs_gtk
class File(unittest.TestCase):
    def test_update_in_place(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "history.jsonl")
        lines = [history.encode_entry("t1", "one"), history.encode_entry("t2", "two \u00e9")]
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        self.assertTrue(history.update_history(("t2", "two \u00e9"), "deux", path))
        self.assertEqual(history.load_entries(path), [("t2", "deux"), ("t1", "one")])
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.loads(f.read().split("\n")[1]), {"time": "t2", "text": "deux"})
        self.assertFalse(history.update_history(("t9", "gone"), "x", path))

    def test_same_shape_as_jq(self):
        self.assertEqual(history.encode_entry("t", 'a "b"'), '{"time":"t","text":"a \\"b\\""}')

    def test_arrival(self):
        a, b, c, d = ("1", "a"), ("2", "b"), ("3", "c"), ("4", "d")
        self.assertEqual(history.arrival([b, a], [b, a]), ("same",))
        self.assertEqual(history.arrival([b, a], [c, b, a]), ("insert", 1, 2))
        self.assertEqual(history.arrival([c, b, a], [d, c, b]), ("insert", 1, 2))  # trimmed
        self.assertEqual(history.arrival([b, a], [("2", "edited"), a]), ("rebuild",))
        self.assertEqual(history.arrival([], [a]), ("rebuild",))


@needs_gtk
class Paste(unittest.TestCase):
    def test_terminal_classes(self):
        for klass in ("tilix,Tilix", "gnome-terminal-server,Gnome-terminal", "kitty,kitty", "st,St"):
            self.assertTrue(history.is_terminal_class(klass), klass)
        for klass in ("gedit,Gedit", "google-chrome,Google-chrome", "", "code,Code"):
            self.assertFalse(history.is_terminal_class(klass), klass)

    def test_app_name(self):
        self.assertEqual(history.app_name("google-chrome,Google-chrome"), "Google Chrome")
        self.assertEqual(history.app_name("gedit"), "Gedit")
        self.assertEqual(history.app_name(""), "the app")


class Pill(unittest.TestCase):
    def test_handoff_round_trip(self):
        self.assertEqual(notify.decode_handoff(notify.encode_handoff("silent", 3500)), ("silent", 3500))
        self.assertEqual(notify.decode_handoff(notify.encode_handoff("done", 0)), ("done", 0))
        self.assertIsNone(notify.decode_handoff(""))
        self.assertTrue(notify.ack_accepted("error 1", "error"))
        self.assertFalse(notify.ack_accepted("error 0", "error"))
        self.assertIsNone(notify.ack_accepted("silent 1", "error"))  # another state's answer

    def test_accepts(self):
        self.assertTrue(notify.accepts("recording", "silent"))
        self.assertTrue(notify.accepts("editing", "done"))
        self.assertFalse(notify.accepts("learned", "silent"))
        self.assertFalse(notify.accepts("silent", "error"))

    def test_close_delay(self):
        self.assertAlmostEqual(notify.close_delay("silent", 3500), 3.18)
        self.assertEqual(notify.close_delay("cancelled", 0), 0.9)
        self.assertIsNone(notify.close_delay("recording", 0))
        self.assertEqual(notify.close_delay("error", 200), 0.1)

    def test_geometry(self):
        self.assertEqual(notify.BAR_BLOCK, 116)
        self.assertEqual(notify.LABEL_X, 144)
        chip = notify.chip_rect(310, 60)
        self.assertEqual(chip, (243, 7, 60, 24))
        self.assertEqual(notify.hit_rect(310, chip), (237, 0, 73, 38))

    def test_curves(self):
        for curve in (notify.CURVE_OUT, notify.CURVE_IN, notify.CURVE_STD):
            self.assertEqual(curve(0), 0)
            self.assertEqual(curve(1), 1)
            values = [curve(i / 20) for i in range(21)]
            self.assertEqual(values, sorted(values))
        self.assertGreater(notify.CURVE_OUT(0.2), 0.5)
        self.assertLess(notify.CURVE_IN(0.2), 0.1)

    def test_bars(self):
        self.assertEqual([notify.ridge(i) for i in range(9)], [4, 5, 6, 7, 8, 7, 6, 5, 4])
        self.assertEqual(notify.still_height("cancelled", 3), notify.MIN_BAR)
        for i in range(notify.NUM_BARS):
            self.assertTrue(8 <= notify.slow_wave(i, 0.3) <= 16)
            self.assertTrue(notify.MIN_BAR <= notify.live_height(1.0, i) <= notify.MAX_BAR)


class DoubleTap(unittest.TestCase):
    def test_second_tap_after_a_start(self):
        tap = hotkey.DoubleTap()
        self.assertFalse(tap.fired(10.0, recording_live=False))  # starts a recording
        self.assertTrue(tap.fired(10.4, recording_live=True))    # opens History

    def test_too_slow(self):
        tap = hotkey.DoubleTap()
        self.assertFalse(tap.fired(10.0, recording_live=False))
        self.assertFalse(tap.fired(10.6, recording_live=True))   # a normal stop

    def test_stop_then_start_records(self):
        tap = hotkey.DoubleTap()
        self.assertFalse(tap.fired(10.0, recording_live=True))   # stops a recording
        self.assertFalse(tap.fired(10.2, recording_live=False))  # starts the next one
        self.assertTrue(tap.fired(10.5, recording_live=True))

    def test_three_taps(self):
        tap = hotkey.DoubleTap()
        tap.fired(10.0, recording_live=False)
        self.assertTrue(tap.fired(10.2, recording_live=True))
        self.assertFalse(tap.fired(10.4, recording_live=False))  # a fresh start, not History again


if __name__ == "__main__":
    unittest.main()
