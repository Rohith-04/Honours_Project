#!/usr/bin/env python3
"""VCS may return zero after $fatal: require an explicit, uncontested PASS."""
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text()
name = re.escape(sys.argv[2])
if not re.search(rf"^TEST {name}: PASS \(\d+ checks\)$", log, re.M) or re.search(
    r"\[FAIL\]|\bFatal:|\bError:|\bFAIL\b|\$error", log
):
    raise SystemExit(f"Simulation failed or did not report PASS: {sys.argv[1]}")
