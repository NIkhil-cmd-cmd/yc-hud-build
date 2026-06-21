"""Cached page replay stub."""

from __future__ import annotations

import json
from pathlib import Path


def replay_cached(harvest_path: Path) -> list[dict]:
    return json.loads(harvest_path.read_text())
