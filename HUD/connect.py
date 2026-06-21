#!/usr/bin/env python3
"""Verify HUD platform connectivity for eval and training (standalone smoke test)."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import Any

from hud.utils.gateway import list_gateway_models
from hud.utils.requests import make_request

from config import HUDConnection, load_settings


async def verify_platform(conn: HUDConnection | None = None) -> dict[str, Any]:
    """Ping HUD API, gateway catalog, and RL service."""
    conn = conn or HUDConnection.from_settings()
    result: dict[str, Any] = {
        "api_url": conn.api_url,
        "gateway_url": conn.gateway_url,
        "rl_url": conn.rl_url,
        "api_key_set": bool(conn.api_key),
    }

    # Platform API — whoami-style check via model resolve endpoint
    try:
        data = await make_request(
            "GET",
            f"{conn.api_url}/v2/models/resolve?model=claude-haiku-4-5",
            api_key=conn.api_key,
        )
        result["api_ok"] = True
        result["sample_model_id"] = data.get("id")
    except Exception as exc:
        result["api_ok"] = False
        result["api_error"] = str(exc)[:200]

    # Gateway model catalog (inference + trainable flags)
    try:
        models = list_gateway_models()
        result["gateway_ok"] = True
        result["gateway_model_count"] = len(models)
        result["trainable_models"] = [
            m.model_name or m.name
            for m in models
            if getattr(m, "trainable", False) or getattr(m, "is_trainable", False)
        ][:8]
    except Exception as exc:
        result["gateway_ok"] = False
        result["gateway_error"] = str(exc)[:200]

    # RL training service — optional health probe (may 404 until a model is forked)
    try:
        await make_request(
            "GET",
            f"{conn.rl_url}/v1/health",
            api_key=conn.api_key,
        )
        result["rl_ok"] = True
    except Exception as exc:
        result["rl_ok"] = False
        result["rl_note"] = str(exc)[:120]

    result["ok"] = result.get("api_ok") and result.get("gateway_ok")
    return result


async def verify_local_env() -> dict[str, Any]:
    """Grade smoke_ping without an agent rollout (template wiring only)."""
    from hud.environment.server import TaskRunner

    from env import env

    task_id = "smoke_ping"
    if task_id not in env.tasks:
        return {"local_env_ok": False, "error": f"task {task_id} missing"}

    runner = TaskRunner(env.tasks[task_id], {"word": "openhive"})
    prompt_frame = await runner.start()
    grade_frame = await runner.grade({"answer": "pong-openhive"})
    reward = float(grade_frame.get("score", 0.0))
    return {
        "local_env_ok": reward >= 1.0,
        "task_id": task_id,
        "prompt": str(prompt_frame.get("prompt", ""))[:120],
        "reward": reward,
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description="Verify HUD platform + local env wiring")
    parser.add_argument("--json", action="store_true", help="Print machine-readable report")
    parser.add_argument("--skip-local", action="store_true", help="Only check platform APIs")
    args = parser.parse_args()

    try:
        load_settings()
        platform = await verify_platform()
        local: dict[str, Any] = {}
        if not args.skip_local:
            local = await verify_local_env()
        report = {"platform": platform, "local": local}
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        p = report["platform"]
        print("HUD connection check")
        print(f"  API ({p['api_url']}):       {'ok' if p.get('api_ok') else 'FAIL'}")
        print(f"  Gateway ({p['gateway_url']}): {'ok' if p.get('gateway_ok') else 'FAIL'} "
              f"({p.get('gateway_model_count', 0)} models)")
        print(f"  RL ({p['rl_url']}):         {'ok' if p.get('rl_ok') else 'skip (fork a model first)'}")
        if p.get("trainable_models"):
            print(f"  Trainable: {', '.join(p['trainable_models'][:5])}")
        if local:
            print(f"  Local env smoke_ping:       {'ok' if local.get('local_env_ok') else 'FAIL'}")
        if not p.get("ok"):
            return 1
    return 0 if report["platform"].get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
