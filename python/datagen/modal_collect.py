"""Modal parallel collection — optional bulk harvest (sync to local disk)."""

from __future__ import annotations

# Stub: requires `modal` CLI and secrets. Run: modal run python/datagen/modal_collect.py

try:
    import modal
except ImportError:
    modal = None

if modal:

    app = modal.App("openhive-collect")
    vol = modal.Volume.from_name("openhive-data", create_if_missing=True)

    @app.function(volumes={"/data": vol}, timeout=600)
    def collect_one(config: dict) -> dict:
        return {"config": config, "status": "stub"}

    @app.local_entrypoint()
    def main():
        import json
        from pathlib import Path

        configs = json.loads(
            (Path(__file__).parents[2] / "configs" / "collection_configs.json").read_text()
        )
        for r in collect_one.map(configs):
            print(r)
