"""Isolated launcher process tests; never opens the real viewer or devices."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "tools/launch-viewer.py"

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()
        (self.root / "app").mkdir()
        self.launcher = self.root / "tools/launch-viewer.py"
        shutil.copyfile(SOURCE, self.launcher)
        self.binary = self.root / "app/switchview"
        self.children = []

    def tearDown(self):
        for p in self.children:
            if p.poll() is None:
                p.terminate()
            p.wait(timeout=5)
        self.tmp.cleanup()

    def run_launcher(self, *args):
        return subprocess.run([sys.executable, str(self.launcher), *args], capture_output=True, text=True, timeout=5)

    def fake_binary(self, delay=0):
        self.binary.write_text("#!" + sys.executable + "\nimport sys,json,time,os\nfrom pathlib import Path\nPath('received.json').write_text(json.dumps({'args':sys.argv[1:],'cwd':os.getcwd()}))\ntime.sleep(" + str(delay) + ")\n")
        self.binary.chmod(0o755)

    def test_missing_binary(self):
        p = self.run_launcher()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Build SwitchView first", p.stderr)

    def test_forwarding_and_root(self):
        self.fake_binary()
        p = self.run_launcher("-d", "A device with spaces", "-H", "none")
        self.assertEqual(p.returncode, 0, p.stderr)
        result = json.loads((self.root / "received.json").read_text())
        self.assertEqual(result['args'], ['-H', 'none', '-d', 'A device with spaces', '-H', 'none'])
        self.assertEqual(Path(result['cwd']).resolve(), self.root.resolve())

    def test_lock_survives_exec_and_releases(self):
        self.fake_binary(30)
        first = subprocess.Popen([sys.executable, str(self.launcher)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(first)
        deadline = time.monotonic() + 5
        while not (self.root / "received.json").exists():
            self.assertIsNone(first.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        second = self.run_launcher()
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("already open", second.stderr)
        first.terminate(); first.wait(timeout=5)
        self.fake_binary()
        self.assertEqual(self.run_launcher().returncode, 0)

    def test_failed_exec_releases_lock(self):
        self.binary.write_text("not executable")
        self.assertNotEqual(self.run_launcher().returncode, 0)
        self.fake_binary()
        self.assertEqual(self.run_launcher().returncode, 0)

if __name__ == '__main__':
    unittest.main()
