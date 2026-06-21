"""Pre-demo validation — assert measured claims before showing in UI."""

from __future__ import annotations

import json
import sys
from pathlib import Path

METRICS_DIR = Path.home() / "Library/Application Support/OpenHive/metrics"


def validate_demo_latest() -> bool:
    path = METRICS_DIR / "demo_latest.json"
    if not path.exists():
        print("demo_latest.json missing — run a workflow execute first")
        return False

    data = json.loads(path.read_text())
    ok = True

    if data.get("elapsedMs", 99999) > 20000:
        print(f"FAIL: elapsed {data['elapsedMs']}ms > 20000ms")
        ok = False

    if data.get("tokens", 999) != 0:
        print(f"FAIL: tokens {data.get('tokens')} != 0")
        ok = False

    tiers = data.get("tierLog", [])
    if tiers and any(t != 1 for t in tiers):
        print(f"WARN: not all T1 tiers: {tiers}")

    if data.get("reward") is not None and data["reward"] < 0.75:
        print(f"WARN: reward {data['reward']} < 0.75")

    if ok:
        print("PASS:", json.dumps(data, indent=2))
    return ok


if __name__ == "__main__":
    sys.exit(0 if validate_demo_latest() else 1)
