#!/usr/bin/env python3
"""Require both the test banner and a clean UVM summary, even if VCS exits zero."""
import re
import sys
from pathlib import Path


def check(log, test):
    banner = r"^TEST " + re.escape(test) + r": PASS \([1-9]\d* checks\)$"
    if not re.search(banner, log, re.M):
        raise ValueError("missing expected nonempty PASS banner")
    for severity in ("UVM_ERROR", "UVM_FATAL"):
        counts = re.findall(r"^" + severity + r"\s*:\s*(\d+)\s*$", log, re.M)
        if not counts or any(int(count) != 0 for count in counts):
            raise ValueError("missing or nonzero " + severity + " summary")
    if re.search(r"^UVM_(?:ERROR|FATAL)\b(?!\s*:)|\bFAIL\b|\bFatal:|\bError:|\$error|\[FAIL\]", log, re.M):
        raise ValueError("failure diagnostic in simulation log")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: check_uvm.py <sim.log> <expected-test-name>")
    try:
        check(Path(sys.argv[1]).read_text(), sys.argv[2])
    except (OSError, ValueError) as exc:
        raise SystemExit("UVM simulation rejected: " + str(exc))
    print("UVM log check PASS: " + sys.argv[2])


if __name__ == "__main__":
    main()
