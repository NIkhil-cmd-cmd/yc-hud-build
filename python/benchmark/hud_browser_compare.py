"""HUD browser benchmark — compare native vs HUD real browser timing."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Awaitable

from task_index import BENCHMARKS_DIR, TRACES_DIR, load_skill, match_task

SendFn = Callable[[dict[str, Any]], Awaitable[None]]


async def run_benchmark(
    send: SendFn,
    *,
    prompt: str | None = None,
    skill_id: str | None = None,
    mode: str = "task",
    trace_id: str | None = None,
) -> dict[str, Any]:
    run_id = f"bench_{uuid.uuid4().hex[:12]}"
    spec = {"runId": run_id, "mode": mode, "prompt": prompt, "skillId": skill_id, "traceId": trace_id}
    await send({"type": "benchmark_progress", "runId": run_id, "phase": "native", "status": "running"})

    native = await _run_native_arm(spec)
    await send({"type": "benchmark_progress", "runId": run_id, "phase": "native", "status": "done", "result": native})
    await send({"type": "benchmark_progress", "runId": run_id, "phase": "hud", "status": "running"})

    hud = await _run_hud_arm(spec)
    await send({"type": "benchmark_progress", "runId": run_id, "phase": "hud", "status": "done", "result": hud})

    report = {
        "runId": run_id,
        "spec": spec,
        "native": native,
        "hud": hud,
        "comparison": {
            "nativeMs": native.get("elapsedMs", 0),
            "hudMs": hud.get("elapsedMs", 0),
            "nativeTokens": native.get("tokens", 0),
            "hudTokens": hud.get("tokens", 0),
            "speedup": round(hud.get("elapsedMs", 1) / max(native.get("elapsedMs", 1), 1), 2),
        },
    }
    BENCHMARKS_DIR.mkdir(parents=True, exist_ok=True)
    (BENCHMARKS_DIR / f"{run_id}.json").write_text(json.dumps(report, indent=2))
    await send({"type": "benchmark_complete", **report})
    return report


async def _run_native_arm(spec: dict[str, Any]) -> dict[str, Any]:
    """Estimate native arm from last demo metrics or trace replay metadata."""
    t0 = time.time()
    metrics_path = Path.home() / "Library/Application Support/OpenHive/metrics/demo_latest.json"
    if metrics_path.exists():
        data = json.loads(metrics_path.read_text())
        return {
            "elapsedMs": data.get("elapsedMs", int((time.time() - t0) * 1000)),
            "tokens": data.get("tokens", 0),
            "steps": data.get("steps", 0),
            "hudGrade": data.get("reward", 0),
            "source": "demo_latest",
        }
    if spec.get("traceId"):
        trace_path = TRACES_DIR / spec["traceId"] / "trace.json"
        if trace_path.exists():
            trace = json.loads(trace_path.read_text())
            return {
                "elapsedMs": trace.get("elapsedMs", 0),
                "tokens": 0,
                "steps": len(trace.get("actions", [])),
                "mdpPath": trace.get("mdpPath", []),
                "source": "trace",
            }
    return {"elapsedMs": int((time.time() - t0) * 1000), "tokens": 0, "steps": 0, "source": "stub"}


async def _run_hud_arm(spec: dict[str, Any]) -> dict[str, Any]:
    """Run HUD eval subprocess (real browser agent baseline)."""
    t0 = time.time()
    hud_env = Path(__file__).resolve().parents[1] / "hud_env.py"
    if not hud_env.exists():
        return {"elapsedMs": 0, "tokens": 0, "error": "hud_env.py not found", "source": "missing"}

    model = os.environ.get("OPENHIVE_HUD_BENCHMARK_MODEL", "gpt-4o-mini")
    cmd = ["hud", "eval", str(hud_env), model, "--max-steps", "25"]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(hud_env.parent),
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=600)
        elapsed_ms = int((time.time() - t0) * 1000)
        output = (stdout or b"").decode() + (stderr or b"").decode()
        tokens = _parse_tokens_from_output(output)
        reward = _parse_reward_from_output(output)
        return {
            "elapsedMs": elapsed_ms,
            "tokens": tokens,
            "hudGrade": reward,
            "exitCode": proc.returncode,
            "source": "hud_eval",
            "outputTail": output[-500:],
        }
    except asyncio.TimeoutError:
        return {"elapsedMs": int((time.time() - t0) * 1000), "tokens": 0, "error": "timeout", "source": "hud_eval"}
    except FileNotFoundError:
        return {
            "elapsedMs": int((time.time() - t0) * 1000),
            "tokens": 0,
            "error": "hud CLI not installed",
            "source": "hud_eval",
        }


def _parse_tokens_from_output(text: str) -> int:
    for line in text.splitlines():
        if "token" in line.lower():
            parts = line.split()
            for p in parts:
                if p.isdigit() and int(p) > 100:
                    return int(p)
    return 0


def _parse_reward_from_output(text: str) -> float:
    for line in text.splitlines():
        if "reward" in line.lower():
            for p in line.replace(":", " ").split():
                try:
                    return float(p)
                except ValueError:
                    continue
    return 0.0


def save_trace(run_id: str, trace: dict[str, Any]) -> Path:
    d = TRACES_DIR / run_id
    d.mkdir(parents=True, exist_ok=True)
    path = d / "trace.json"
    path.write_text(json.dumps(trace, indent=2))
    return path


async def _cli_main() -> None:
    import sys

    prompt = None
    skill_id = None
    mode = "task"
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--task" and i + 1 < len(args):
            prompt = args[i + 1]
            i += 2
        elif args[i] == "--skill" and i + 1 < len(args):
            skill_id = args[i + 1]
            i += 2
        elif args[i] == "--mode" and i + 1 < len(args):
            mode = args[i + 1]
            i += 2
        else:
            i += 1

    async def print_send(payload: dict[str, Any]) -> None:
        print(json.dumps(payload))

    report = await run_benchmark(print_send, prompt=prompt, skill_id=skill_id, mode=mode)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    asyncio.run(_cli_main())
