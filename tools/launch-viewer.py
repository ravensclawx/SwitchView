#!/usr/bin/env python3
"""Open one local viewer; input stays disconnected unless explicitly configured."""
import fcntl
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
binary = root / "app" / "switchview"
if not binary.is_file():
    sys.exit("Build SwitchView first; see MACOS.md.")
lock = os.open(root / ".viewer.lock", os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit("SwitchView is already open. Use its existing window.")
os.set_inheritable(lock, True)
os.chdir(root)
os.execv(binary, [str(binary), "-H", "none", *sys.argv[1:]])
