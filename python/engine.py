"""OpenHive Python engine — WebSocket server for Swift browser bridge."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import websockets

from executor import PolicyExecutor
from observer import Observer
from train import compile_workflow_from_buffer, build_graph, value_iteration

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("openhive.engine")

APP_SUPPORT = Path.home() / "Library/Application Support/OpenHive"
HARVEST_DIR = APP_SUPPORT / "harvest"
WORKFLOW_DIR = APP_SUPPORT / "workflows"
METRICS_DIR = APP_SUPPORT / "metrics"

for d in (HARVEST_DIR, WORKFLOW_DIR, METRICS_DIR):
    d.mkdir(parents=True, exist_ok=True)

_observers: dict[str, Observer] = {}
_executors: dict[str, PolicyExecutor] = {}
_exec_meta: dict[str, dict[str, Any]] = {}


async def _send(ws: websockets.WebSocketServerProtocol, payload: dict[str, Any]) -> None:
    await ws.send(json.dumps(payload))


def _load_workflow(workflow_id: str) -> dict | None:
    path = WORKFLOW_DIR / f"{workflow_id}.json"
    if not path.exists():
        for p in WORKFLOW_DIR.glob("*.json"):
            data = json.loads(p.read_text())
            if data.get("id") == workflow_id:
                return data
        return None
    return json.loads(path.read_text())


def _append_token_metric(msg: dict[str, Any]) -> None:
    path = METRICS_DIR / "tokens.json"
    data = (
        json.loads(path.read_text())
        if path.exists()
        else {
            "sessionTotal": 0,
            "todayTotal": 0,
            "allTimeTotal": 0,
            "byTier": {"1": 0, "2": 0, "3": 0},
            "recentRuns": [],
        }
    )
    tokens = int(msg.get("tokens", 0))
    data["sessionTotal"] += tokens
    data["todayTotal"] += tokens
    data["allTimeTotal"] += tokens
    tier = str(msg.get("tier", 1))
    data["byTier"][tier] = data["byTier"].get(tier, 0) + tokens
    data["recentRuns"].insert(
        0,
        {
            "workflowId": msg.get("workflowId", ""),
            "workflowName": msg.get("workflowName", ""),
            "runType": msg.get("runType", "execute"),
            "tokens": tokens,
            "elapsedMs": msg.get("elapsedMs", 0),
            "tierLog": msg.get("tierLog", []),
        },
    )
    data["recentRuns"] = data["recentRuns"][:50]
    path.write_text(json.dumps(data, indent=2))


async def handle(ws: websockets.WebSocketServerProtocol) -> None:
    session_id = "default"
    conn_id = id(ws)
    log.info("client connected")

    async for raw in ws:
        msg = json.loads(raw)
        kind = msg.get("type", "")

        match kind:
            case "attach_observer":
                session_id = msg.get("sessionId", session_id)

                async def on_step(step: dict, sid: str = session_id) -> None:
                    obs = _observers.get(sid)
                    count = len(obs.buffer) if obs else 0
                    await _send(
                        ws,
                        {
                            "type": "step_observed",
                            "sessionId": sid,
                            "count": count,
                            "url": step.get("url", ""),
                        },
                    )

                _observers[session_id] = Observer(session_id=session_id, on_step=on_step)
                await _send(ws, {"type": "observer_attached", "sessionId": session_id})

            case "observe_event":
                session_id = msg.get("sessionId", session_id)
                observer = _observers.get(session_id)
                if observer:
                    await observer.ingest(msg.get("event", {}))

            case "compile_workflow":
                session_id = msg.get("sessionId", session_id)
                name = msg.get("name", "Untitled workflow")
                observer = _observers.get(session_id)
                if not observer or not observer.buffer:
                    await _send(ws, {"type": "error", "message": "No steps to compile"})
                    continue
                workflow = compile_workflow_from_buffer(name, observer.buffer)
                wid = workflow["id"]
                (WORKFLOW_DIR / f"{wid}.json").write_text(json.dumps(workflow, indent=2))
                await _send(
                    ws,
                    {
                        "type": "workflow_saved",
                        "workflow": {
                            "id": wid,
                            "name": name,
                            "steps": len(observer.buffer),
                        },
                    },
                )

            case "import_harvest":
                path = Path(msg.get("path", ""))
                if not path.exists():
                    await _send(ws, {"type": "error", "message": "harvest not found"})
                    continue
                steps = []
                if path.suffix == ".jsonl":
                    steps = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
                else:
                    data = json.loads(path.read_text())
                    steps = data.get("steps", data.get("harvest", []))
                name = msg.get("name", path.stem)
                workflow = compile_workflow_from_buffer(name, steps)
                (WORKFLOW_DIR / f"{workflow['id']}.json").write_text(json.dumps(workflow, indent=2))
                await _send(ws, {"type": "workflow_saved", "workflow": workflow})

            case "generate_synthetic":
                from datagen.synthetic import generate_configs

                configs = generate_configs(msg.get("limit", 15))
                configs_path = Path(__file__).parents[1] / "configs" / "collection_configs.json"
                configs_path.write_text(json.dumps(configs, indent=2))
                await _send(ws, {"type": "synthetic_generated", "count": len(configs)})

            case "execute_workflow":
                workflow_id = msg.get("workflowId", "")
                wf = _load_workflow(workflow_id)
                if not wf:
                    await _send(ws, {"type": "error", "message": "Workflow not found"})
                    continue
                _executors[conn_id] = PolicyExecutor(wf, msg.get("params", {}))
                _exec_meta[conn_id] = {
                    "t0": time.time(),
                    "workflowId": workflow_id,
                    "workflowName": wf.get("name", ""),
                    "steps": 0,
                }
                await _send(ws, {"type": "execute_started", "workflowId": workflow_id})

            case "execute_state":
                executor = _executors.get(conn_id)
                meta = _exec_meta.get(conn_id, {})
                if not executor:
                    await _send(ws, {"type": "error", "message": "No active execution"})
                    continue

                meta["steps"] = meta.get("steps", 0) + 1
                if meta["steps"] > 25:
                    await _send(ws, {"type": "execute_done", "reason": "max_steps"})
                    _executors.pop(conn_id, None)
                    continue

                result = await executor.next_action(
                    msg.get("url", ""),
                    msg.get("title", ""),
                    msg.get("accessibilityTree"),
                )
                elapsed_ms = int((time.time() - meta.get("t0", time.time())) * 1000)
                metric = {
                    "type": "metric",
                    "tokens": result.get("tokens", executor.tokens),
                    "tier": result.get("tier", 1),
                    "elapsedMs": elapsed_ms,
                    "workflowName": meta.get("workflowName", ""),
                    "workflowId": meta.get("workflowId", ""),
                    "runType": "execute",
                    "tierLog": executor.tier_log,
                }
                _append_token_metric(metric)
                await _send(ws, {"type": "run_metric", **metric})

                if result.get("done") or not result.get("action"):
                    demo = {
                        "tokens": executor.tokens,
                        "elapsedMs": elapsed_ms,
                        "tierLog": executor.tier_log,
                        "steps": meta.get("steps", 0),
                    }
                    (METRICS_DIR / "demo_latest.json").write_text(json.dumps(demo, indent=2))
                    await _send(
                        ws,
                        {
                            "type": "execute_done",
                            "tokens": executor.tokens,
                            "elapsedMs": elapsed_ms,
                            "tierLog": executor.tier_log,
                        },
                    )
                    _executors.pop(conn_id, None)
                    _exec_meta.pop(conn_id, None)
                else:
                    await _send(
                        ws,
                        {
                            "type": "execute_action",
                            "action": result.get("action", {}),
                            "tier": result.get("tier", 1),
                            "tokens": result.get("tokens", 0),
                            "sim": result.get("sim"),
                        },
                    )

            case "cancel_execute":
                _executors.pop(conn_id, None)
                _exec_meta.pop(conn_id, None)
                await _send(ws, {"type": "execute_cancelled"})

            case "list_workflows":
                workflows = []
                for p in sorted(WORKFLOW_DIR.glob("*.json")):
                    data = json.loads(p.read_text())
                    workflows.append(
                        {
                            "id": data.get("id", p.stem),
                            "name": data.get("name", p.stem),
                            "steps": data.get("steps", 0),
                        }
                    )
                await _send(ws, {"type": "workflows_list", "workflows": workflows})

            case "get_token_metrics":
                metrics_path = METRICS_DIR / "tokens.json"
                data = (
                    json.loads(metrics_path.read_text())
                    if metrics_path.exists()
                    else {
                        "sessionTotal": 0,
                        "todayTotal": 0,
                        "allTimeTotal": 0,
                        "byTier": {"1": 0, "2": 0, "3": 0},
                        "recentRuns": [],
                    }
                )
                await _send(ws, {"type": "token_metrics", "metrics": data})

            case "metric":
                _append_token_metric(msg)
                await _send(ws, {"type": "metric_ack", "ok": True})

            case "ping":
                await _send(ws, {"type": "pong"})

            case _:
                await _send(ws, {"type": "error", "message": f"unknown type: {kind}"})


async def main() -> None:
    port = int(os.environ.get("OPENHIVE_ENGINE_PORT", "8765"))
    log.info("starting engine on ws://localhost:%s", port)
    async with websockets.serve(handle, "localhost", port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
