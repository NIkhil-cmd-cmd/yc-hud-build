"""OpenHive Python engine — WebSocket server for Swift browser bridge."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any

import websockets
from websockets.server import WebSocketServerProtocol

from observer import Observer
from train import compile_workflow_from_buffer

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("openhive.engine")

APP_SUPPORT = Path.home() / "Library/Application Support/OpenHive"
HARVEST_DIR = APP_SUPPORT / "harvest"
WORKFLOW_DIR = APP_SUPPORT / "workflows"
METRICS_DIR = APP_SUPPORT / "metrics"

for d in (HARVEST_DIR, WORKFLOW_DIR, METRICS_DIR):
    d.mkdir(parents=True, exist_ok=True)

# Per-connection observer instances keyed by session id
_observers: dict[str, Observer] = {}


async def _send(ws: WebSocketServerProtocol, payload: dict[str, Any]) -> None:
    await ws.send(json.dumps(payload))


async def handle(ws: WebSocketServerProtocol) -> None:
    session_id = "default"
    log.info("client connected")

    async for raw in ws:
        msg = json.loads(raw)
        kind = msg.get("type", "")

        match kind:
            case "attach_observer":
                session_id = msg.get("sessionId", session_id)
                observer = Observer(
                    session_id=session_id,
                    on_step=lambda step: asyncio.create_task(
                        _send(
                            ws,
                            {
                                "type": "step_observed",
                                "sessionId": session_id,
                                "count": len(_observers[session_id].buffer),
                                "url": step.get("url", ""),
                            },
                        )
                    ),
                )
                _observers[session_id] = observer
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
                path = WORKFLOW_DIR / f"{wid}.json"
                path.write_text(json.dumps(workflow, indent=2))
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
                if metrics_path.exists():
                    data = json.loads(metrics_path.read_text())
                else:
                    data = {
                        "sessionTotal": 0,
                        "todayTotal": 0,
                        "allTimeTotal": 0,
                        "byTier": {"1": 0, "2": 0, "3": 0},
                        "recentRuns": [],
                    }
                await _send(ws, {"type": "token_metrics", "metrics": data})

            case "metric":
                # Executor reports token usage — append to tokens.json
                _append_token_metric(msg)
                await _send(ws, {"type": "metric_ack", "ok": True})

            case "ping":
                await _send(ws, {"type": "pong"})

            case _:
                await _send(ws, {"type": "error", "message": f"unknown type: {kind}"})


def _append_token_metric(msg: dict[str, Any]) -> None:
    path = METRICS_DIR / "tokens.json"
    if path.exists():
        data = json.loads(path.read_text())
    else:
        data = {
            "sessionTotal": 0,
            "todayTotal": 0,
            "allTimeTotal": 0,
            "byTier": {"1": 0, "2": 0, "3": 0},
            "recentRuns": [],
        }

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


async def main() -> None:
    port = int(os.environ.get("OPENHIVE_ENGINE_PORT", "8765"))
    log.info("starting engine on ws://localhost:%s", port)
    async with websockets.serve(handle, "localhost", port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
