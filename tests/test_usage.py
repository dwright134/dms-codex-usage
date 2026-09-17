import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "get-codex-usage.py"
spec = importlib.util.spec_from_file_location("usage", SCRIPT)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


def line(stamp, total, inp, cached, written, out, model=None):
    rows = []
    if model:
        rows.append(json.dumps({"type": "turn_context", "payload": {"model": model}}))
    payload = {"type": "token_count", "info": {"total_token_usage": {
        "total_tokens": total, "input_tokens": inp, "cached_input_tokens": cached,
        "cache_write_input_tokens": written, "output_tokens": out,
        "reasoning_output_tokens": out // 2}}}
    rows.append(json.dumps({"timestamp": stamp, "payload": payload}))
    return "\n".join(rows) + "\n"


class CostTests(unittest.TestCase):
    def test_cached_input_is_a_discounted_subset(self):
        parts = {"input_tokens": 200_000, "cached_input_tokens": 160_000,
                 "cache_write_input_tokens": 0, "output_tokens": 100_000,
                 "reasoning_output_tokens": 50_000}
        self.assertAlmostEqual(usage.estimate_cost("gpt-5.6-sol", parts), 2.224)

    def test_reasoning_is_not_added_to_output(self):
        base = {"input_tokens": 0, "cached_input_tokens": 0,
                "cache_write_input_tokens": 0, "output_tokens": 100_000}
        self.assertEqual(usage.estimate_cost("gpt-5.5", base),
                         usage.estimate_cost("gpt-5.5", dict(base, reasoning_output_tokens=90_000)))

    def test_long_context_multiplier(self):
        parts = {"input_tokens": 300_000, "cached_input_tokens": 0,
                 "cache_write_input_tokens": 0, "output_tokens": 100_000}
        self.assertAlmostEqual(usage.estimate_cost("gpt-5.4", parts), 3.75)

    def test_unknown_model_is_unpriced(self):
        self.assertIsNone(usage.estimate_cost("future-model", {"input_tokens": 10}))


class SessionTests(unittest.TestCase):
    def test_cumulative_counters_are_counted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text(line("2026-09-17T12:00:00Z", 100, 80, 40, 0, 20, "gpt-5.6-sol")
                            + line("2026-09-17T12:01:00Z", 100, 80, 40, 0, 20)
                            + line("2026-09-17T12:02:00Z", 180, 140, 70, 0, 40))
            day = usage.parse_session(path)["days"]["2026-09-17"]
            self.assertEqual(day["tokens"], 180)
            self.assertEqual(day["parts"]["input_tokens"], 140)
            self.assertGreater(day["cost"], 0)

    def test_model_switch_attributes_each_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text(line("2026-09-17T12:00:00Z", 100, 80, 40, 0, 20, "gpt-5.4")
                            + line("2026-09-17T12:02:00Z", 180, 140, 70, 0, 40, "gpt-5.5"))
            models = usage.parse_session(path)["days"]["2026-09-17"]["models"]
            self.assertEqual(models["gpt-5.4"]["tokens"], 100)
            self.assertEqual(models["gpt-5.5"]["tokens"], 80)

    def test_activity_calendar_month_and_rolling_week(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "sessions"
            root.mkdir()
            (root / "session.jsonl").write_text(
                line("2026-08-31T12:00:00Z", 100, 80, 40, 0, 20, "gpt-5.4")
                + line("2026-09-17T12:00:00Z", 250, 200, 100, 0, 50))
            result = usage.activity(root, Path(directory) / "cache.json", dt.date(2026, 9, 17))
            self.assertEqual(result["today"], 150)
            self.assertEqual(result["week"], 150)
            self.assertEqual(result["month"], 150)
            self.assertEqual(result["first_activity"],
                             int(dt.datetime(2026, 9, 17, 12, tzinfo=dt.timezone.utc).timestamp()))
            self.assertEqual(len(result["daily30"]), 30)


class PacingTests(unittest.TestCase):
    def test_synthetic_five_hour_budget(self):
        reset = 2_000_000_000
        duration = 10080 * 60
        start = reset - duration
        now = start + 2 * 18000 + 9000
        weekly = {"used": 11.5, "minutes": 10080, "reset": reset}
        points = [{"at": start + 2 * 18000, "used": 10.0, "reset": reset}]
        result = usage.synthetic_five(weekly, points, now)
        self.assertAlmostEqual(result["used"], 50.4, places=1)
        self.assertTrue(result["estimated"])
        self.assertEqual(result["reset"], start + 3 * 18000)

    def test_synthetic_window_advances_from_first_activity(self):
        activity = int(dt.datetime(2026, 9, 17, 14, 12, 55,
                                   tzinfo=dt.timezone.utc).timestamp())
        anchor = int(dt.datetime(2026, 9, 17, 14, 15,
                                 tzinfo=dt.timezone.utc).timestamp())
        weekly = {"used": 8, "minutes": 10080, "reset": anchor + 6 * 86400}
        points = [{"at": activity, "used": 0, "reset": weekly["reset"]},
                  {"at": anchor + 5 * 3600, "used": 7.5, "reset": weekly["reset"]}]
        result = usage.synthetic_five(weekly, points, anchor + 5 * 3600 + 1800, activity)
        self.assertEqual(result["reset"], anchor + 10 * 3600)
        self.assertAlmostEqual(result["used"], 16.8, places=1)
        self.assertAlmostEqual(result["pace_delta"], 6.8, places=1)
        self.assertIn("2:15 PM to 7:15 PM", result["description"])

    def test_server_window_normalization(self):
        value = usage.window({"usedPercent": 12, "windowDurationMins": 10080,
                              "resetsAt": 12345})
        self.assertEqual(value, {"used": 12.0, "minutes": 10080, "reset": 12345})


class MetadataTests(unittest.TestCase):
    def test_version_files_match(self):
        root = Path(__file__).resolve().parents[1]
        manifest = json.loads((root / "plugin.json").read_text())
        self.assertEqual((root / "VERSION").read_text().strip(), manifest["version"])
        self.assertEqual(manifest["version"], usage.VERSION)

    def test_required_files_exist(self):
        root = Path(__file__).resolve().parents[1]
        for name in ("CodexUsageWidget.qml", "CodexUsageSettings.qml", "plugin.json", "VERSION"):
            self.assertTrue((root / name).is_file(), name)


if __name__ == "__main__":
    unittest.main()
