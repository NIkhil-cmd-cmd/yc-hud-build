"""Generate FlightParams permutations for local datagen."""

from __future__ import annotations

import json
from pathlib import Path

ORIGINS = ["BOS", "SFO", "JFK", "LAX", "ORD", "ATL", "SEA", "DEN"]
DESTINATIONS = ["LAX", "JFK", "MIA", "DEN", "SEA", "BOS", "SFO", "ORD"]
DATES = ["2026-07-15", "2026-07-20", "2026-08-01", "2026-08-15"]


def generate_configs(limit: int = 15) -> list[dict]:
    configs = []
    for o in ORIGINS:
        for d in DESTINATIONS:
            if o == d:
                continue
            for date in DATES:
                configs.append({"origin": o, "destination": d, "date": date})
                if len(configs) >= limit:
                    return configs
    return configs


if __name__ == "__main__":
    out = Path(__file__).resolve().parents[1] / "configs" / "collection_configs.json"
    out.write_text(json.dumps(generate_configs(), indent=2))
    print(f"wrote {len(generate_configs())} configs to {out}")
