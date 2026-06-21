"""Import harvest JSON from HUD eval runs into OpenHive harvest dir."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

HARVEST_DIR = Path.home() / "Library/Application Support/OpenHive/harvest"


def import_harvest(source: Path) -> Path:
    HARVEST_DIR.mkdir(parents=True, exist_ok=True)
    dest = HARVEST_DIR / source.name
    shutil.copy2(source, dest)
    return dest


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("usage: python hud_import.py <harvest.json>")
        raise SystemExit(1)
    print(import_harvest(Path(sys.argv[1])))
