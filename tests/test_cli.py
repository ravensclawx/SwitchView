"""CLI rejection must happen before SDL initialization or device access."""
import os
from pathlib import Path
import subprocess
import unittest

BINARY = Path(os.environ.get("SWITCHVIEW_BIN", Path(__file__).resolve().parents[1] / "app/switchview"))


class CommandLineTests(unittest.TestCase):
    def test_invalid_options_fail_before_help(self):
        cases = [
            ("-r", "30junk"), ("-r", "1e3"), ("-r", "1001"),
            ("-P", "65536"), ("-P", "999999999999999999999999"),
            ("-P", "1junk"), ("-P", "-1"),
            ("-s", "1920x1080junk"), ("-s", "0x1080"), ("-s", "16385x1"),
            ("-l", "4001"), ("-l", "20ms"), ("-m", "nan"),
            ("-m", "inf"), ("-m", "-inf"), ("-m", "1junk"),
            ("-m", "0"), ("-m", "101"), ("-p", "invalid"),
        ]
        for args in cases:
            with self.subTest(args=args):
                result = subprocess.run([str(BINARY), *args, "-h"], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("render:", result.stderr)

    def test_valid_values_reach_help_without_devices(self):
        result = subprocess.run([str(BINARY), "-s", "1920x1080", "-r", "30", "-l", "20",
                                 "-P", "65535", "-m", "0.5", "-H", "none", "-h"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage:", result.stderr)

    def test_extra_argument_rejected(self):
        result = subprocess.run([str(BINARY), "unexpected"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("unexpected argument", result.stderr)


if __name__ == "__main__":
    unittest.main()
