"""Modal parallel collection — runs collector per config on Modal workers."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def collect_one_local(config: dict) -> dict:
    """Run a single trace locally via collector module."""
    cfg_path = REPO_ROOT / "artifacts" / "_modal_config.json"
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(json.dumps(config))
    cmd = [
        sys.executable,
        str(REPO_ROOT / "python" / "collector.py"),
        "--gate",
        "--limit",
        "1",
    ]
    env = {**dict(**__import__("os").environ)}
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT / "python"), capture_output=True, text=True, env=env)
    return {
        "config": config,
        "status": "ok" if proc.returncode == 0 else "error",
        "stdout": proc.stdout[-2000:],
        "stderr": proc.stderr[-1000:],
    }


try:
    import modal
except ImportError:
    modal = None


if modal:

    app = modal.App("openhive-collect")
    image = modal.Image.debian_slim(python_version="3.12").pip_install(
        "playwright", "openai", "networkx", "websockets", "exa-py"
    ).run_commands("playwright install chromium")
    vol = modal.Volume.from_name("openhive-data", create_if_missing=True)

    @app.function(image=image, volumes={"/data": vol}, timeout=900, secrets=[modal.Secret.from_name("openhive-env", required=False)])
    def collect_one_remote(config: dict) -> dict:
        # Remote stub — mount repo in production; local entrypoint used for dev
        return {"config": config, "status": "remote_stub"}

    @app.local_entrypoint()
    def main(limit: int = 3):
        configs = json.loads((REPO_ROOT / "configs" / "collection_configs.json").read_text())
        configs = configs[:limit]
        results = [collect_one_local(c) for c in configs]
        out = REPO_ROOT / "artifacts" / "modal_collect_report.json"
        out.write_text(json.dumps(results, indent=2))
        print(json.dumps({"collected": len(results), "report": str(out)}, indent=2))


if __name__ == "__main__":
    configs_path = REPO_ROOT / "configs" / "collection_configs.json"
    if configs_path.exists():
        configs = json.loads(configs_path.read_text())[:3]
    else:
        from datagen.synthetic import generate_configs

        configs = generate_configs(limit=3)
    for cfg in configs:
        print(collect_one_local(cfg))
