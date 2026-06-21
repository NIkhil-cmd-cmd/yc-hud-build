#!/usr/bin/env python3
"""Benchmark Google Flights tasks with browser-use (same matrix as local smoke gate)."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

from browser_use_runner import browser_use_enabled, run_flight_trajectory
from smoke.run_local_browser_trace_gate import TASK_MATRIX, reached_results


def task_dict(origin: str, destination: str, depart_date: str) -> dict[str, str]:
    return {"origin": origin, "destination": destination, "departDate": depart_date}


def task_matrix_dicts(limit: int) -> list[dict[str, str]]:
    return [task_dict(o, d, dt) for o, d, dt in TASK_MATRIX[:limit]]


async def run_one(task: dict[str, str], idx: int) -> dict:
    results: list[dict] = []

    async def send(payload: dict) -> None:
        if payload.get("type") == "agent_step":
            step = payload.get("step")
            action = payload.get("action", "")[:60]
            url = (payload.get("url") or "")[:70]
            print(f"  [{idx}] step {step}: {action} @ {url}")
        results.append(payload)

    t0 = time.time()
    outcome = await run_flight_trajectory(send, task, max_steps=int(os.getenv("OPENHIVE_BENCHMARK_MAX_STEPS", "40")))
    elapsed = round(time.time() - t0, 1)

    final = next((r for r in reversed(results) if r.get("type") == "trajectory_complete"), {})
    result_text = final.get("result") or ""
    summary = {
        "url": final.get("finalUrl", ""),
        "title": "",
        "text": result_text,
    }
    detected = reached_results(summary) or bool(final.get("success"))
    return {
        "index": idx,
        "task": task,
        "success": detected or bool(outcome.get("success")),
        "steps": outcome.get("steps", 0),
        "elapsedSec": elapsed,
        "finalUrl": outcome.get("finalUrl", ""),
        "result": result_text[:300],
    }


async def main() -> int:
    if not browser_use_enabled():
        print("OPENHIVE_USE_BROWSER_USE=0 — enable browser-use for benchmark")
        return 1
    if not os.environ.get("OPENAI_API_KEY"):
        print("Set OPENAI_API_KEY in .env")
        return 1

    limit = int(os.getenv("BENCHMARK_LIMIT", "3"))
    tasks = task_matrix_dicts(limit)
    print(f"browser-use benchmark — {len(tasks)} flight task(s), model={os.getenv('OPENHIVE_AGENT_MODEL', 'gpt-4o-mini')}")
    print("")

    rows = []
    for i, task in enumerate(tasks, start=1):
        label = f"{task['origin']}→{task['destination']} {task['departDate']}"
        print(f"=== Task {i}/{len(tasks)}: {label} ===")
        row = await run_one(task, i)
        rows.append(row)
        status = "PASS" if row["success"] else "FAIL"
        print(f"→ {status} in {row['elapsedSec']}s ({row['steps']} steps)\n")

    passed = sum(1 for r in rows if r["success"])
    print(f"Results: {passed}/{len(rows)} passed")
    out = ROOT / "artifacts" / "browser-use-benchmark"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"run_{int(time.time())}.json"
    path.write_text(json.dumps({"passed": passed, "total": len(rows), "rows": rows}, indent=2))
    print(f"Wrote {path}")
    return 0 if passed == len(rows) else 1


if __name__ == "__main__":
    if (ROOT / ".env").exists():
        for line in (ROOT / ".env").read_text().splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())
    raise SystemExit(asyncio.run(main()))
