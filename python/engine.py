"""OpenHive Python engine — WebSocket server for Swift browser bridge."""

from __future__ import annotations

import asyncio
import json
import os
import time
import traceback
from pathlib import Path
from typing import Any

import websockets

from executor import PolicyExecutor
from hud_grade import grade_execution
from log_config import log_event, setup_logging
from observer import Observer
from playwright_runner import PlaywrightRunner
from train import compile_workflow_from_buffer

log = setup_logging("openhive.engine")

APP_SUPPORT = Path.home() / "Library/Application Support/OpenHive"
HARVEST_DIR = APP_SUPPORT / "harvest"
WORKFLOW_DIR = APP_SUPPORT / "workflows"
METRICS_DIR = APP_SUPPORT / "metrics"
LOG_DIR = APP_SUPPORT / "logs"

for d in (HARVEST_DIR, WORKFLOW_DIR, METRICS_DIR, LOG_DIR):
    d.mkdir(parents=True, exist_ok=True)

_observers: dict[str, Observer] = {}
_executors: dict[str, PolicyExecutor] = {}
_exec_meta: dict[str, dict[str, Any]] = {}
_playwright_runners: dict[int, PlaywrightRunner] = {}
_playwright_tasks: dict[int, asyncio.Task] = {}


async def _finish_execution(
    ws: websockets.WebSocketServerProtocol,
    conn_id: int,
    meta: dict[str, Any],
    executor: PolicyExecutor | None,
    *,
    reason: str = "done",
) -> None:
    """Complete a workflow run, grade via HUD, and notify Swift."""
    elapsed_ms = int((time.time() - meta.get("t0", time.time())) * 1000)
    outcome = {
        "url": meta.get("last_url", ""),
        "title": meta.get("last_title", ""),
        "accessibilityTree": meta.get("last_tree"),
        "workflowName": meta.get("workflowName", ""),
        "workflowId": meta.get("workflowId", ""),
        "params": meta.get("params", {}),
        "actionsExecuted": meta.get("actions_executed", []),
        "steps": meta.get("steps", 0),
        "reason": reason,
    }
    grade = await grade_execution(outcome)
    reward = float(grade.get("reward", 0.0))

    demo = {
        "tokens": executor.tokens if executor else 0,
        "elapsedMs": elapsed_ms,
        "tierLog": executor.tier_log if executor else [],
        "steps": meta.get("steps", 0),
        "reward": reward,
        "hudStatus": grade.get("status"),
        "hudTaskId": grade.get("taskId"),
    }
    (METRICS_DIR / "demo_latest.json").write_text(json.dumps(demo, indent=2))
    log_event(
        log,
        "execute_done",
        workflow_id=meta.get("workflowId"),
        reward=reward,
        steps=meta.get("steps", 0),
        elapsed_ms=elapsed_ms,
        hud_status=grade.get("status"),
    )

    metric = {
        "type": "metric",
        "tokens": demo["tokens"],
        "tier": 1,
        "elapsedMs": elapsed_ms,
        "workflowName": meta.get("workflowName", ""),
        "workflowId": meta.get("workflowId", ""),
        "runType": "execute",
        "tierLog": demo["tierLog"],
        "reward": reward,
    }
    _append_token_metric(metric)
    await _send(ws, {"type": "run_metric", **metric})

    await _send(
        ws,
        {
            "type": "execute_done",
            "tokens": demo["tokens"],
            "elapsedMs": elapsed_ms,
            "tierLog": demo["tierLog"],
            "reward": reward,
            "hudStatus": grade.get("status"),
            "hudTaskId": grade.get("taskId"),
            "hudContent": grade.get("content"),
            "reason": reason,
        },
    )
    _executors.pop(conn_id, None)
    _exec_meta.pop(conn_id, None)


def _use_playwright() -> bool:
    return os.environ.get("OPENHIVE_USE_PLAYWRIGHT", "0") == "1"


async def _cancel_playwright_execution(conn_id: int) -> None:
    task = _playwright_tasks.pop(conn_id, None)
    if task and not task.done():
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    runner = _playwright_runners.pop(conn_id, None)
    if runner:
        await runner.close()
    _executors.pop(conn_id, None)
    _exec_meta.pop(conn_id, None)


async def _run_playwright_workflow(
    ws: websockets.WebSocketServerProtocol,
    conn_id: int,
    workflow: dict[str, Any],
    params: dict[str, str],
) -> None:
    """Execute workflow in a real Chromium window via Playwright."""
    workflow_id = workflow.get("id", "")
    executor = PolicyExecutor(workflow, params)
    meta: dict[str, Any] = {
        "t0": time.time(),
        "workflowId": workflow_id,
        "workflowName": workflow.get("name", ""),
        "params": params,
        "steps": 0,
        "actions_executed": [],
        "last_url": "",
        "last_title": "",
        "last_tree": None,
    }
    _executors[conn_id] = executor
    _exec_meta[conn_id] = meta

    runner = PlaywrightRunner()
    _playwright_runners[conn_id] = runner

    try:
        await runner.start()
        await _send(
            ws,
            {
                "type": "execute_started",
                "workflowId": workflow_id,
                "backend": "playwright",
            },
        )

        while meta["steps"] < 25:
            state = await runner.get_state()
            meta["last_url"] = state["url"]
            meta["last_title"] = state["title"]
            meta["last_tree"] = state["accessibilityTree"]

            result = await executor.next_action(
                state["url"],
                state["title"],
                state["accessibilityTree"],
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
                await _finish_execution(ws, conn_id, meta, executor, reason=result.get("reason", "done"))
                return

            action = result.get("action", {})
            meta["steps"] += 1
            meta.setdefault("actions_executed", []).append(action)
            log_event(
                log,
                "execute_action",
                backend="playwright",
                action_type=action.get("type"),
                tier=result.get("tier"),
            )
            await _send(
                ws,
                {
                    "type": "execute_action",
                    "backend": "playwright",
                    "action": action,
                    "tier": result.get("tier", 1),
                    "tokens": result.get("tokens", 0),
                    "sim": result.get("sim"),
                    "step": result.get("step"),
                    "total": result.get("total"),
                },
            )

            ok, detail = await runner.perform_action(action)
            log_event(log, "playwright_action", ok=ok, detail=detail[:120])
            if not ok:
                log_event(log, "playwright_action_failed", action=action, detail=detail)

            await asyncio.sleep(0.2)

        await _finish_execution(ws, conn_id, meta, executor, reason="max_steps")
    except asyncio.CancelledError:
        await _send(ws, {"type": "execute_cancelled"})
        raise
    except Exception as exc:
        log.error("playwright_workflow_failed\n%s", traceback.format_exc())
        await _send(ws, {"type": "error", "message": f"Playwright: {str(exc)[:180]}"})
        await _finish_execution(ws, conn_id, meta, executor, reason="error")
    finally:
        await runner.close()
        _playwright_runners.pop(conn_id, None)
        _playwright_tasks.pop(conn_id, None)


def _keys_env() -> dict[str, bool]:
    return {
        "OPENAI_API_KEY": bool(os.environ.get("OPENAI_API_KEY")),
        "EXA_API_KEY": bool(os.environ.get("EXA_API_KEY")),
        "FIREWORKS_API_KEY": bool(os.environ.get("FIREWORKS_API_KEY")),
        "MINIMAX_API_KEY": bool(os.environ.get("MINIMAX_API_KEY")),
        "HUD_API_KEY": bool(os.environ.get("HUD_API_KEY")),
    }


async def _send(ws: websockets.WebSocketServerProtocol, payload: dict[str, Any]) -> None:
    log_event(log, "ws_send", type=payload.get("type"), payload=_summarize(payload))
    await ws.send(json.dumps(payload))


def _summarize(msg: dict[str, Any]) -> dict[str, Any]:
    """Trim large payloads for logs."""
    out: dict[str, Any] = {}
    for k, v in msg.items():
        if k in ("accessibilityTree", "event") and isinstance(v, dict):
            out[k] = {"keys": list(v.keys())[:8], "type": v.get("type")}
        elif k == "workflows" and isinstance(v, list):
            out[k] = f"{len(v)} workflows"
        elif isinstance(v, str) and len(v) > 120:
            out[k] = v[:120] + "…"
        else:
            out[k] = v
    return out


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
            "reward": msg.get("reward"),
        },
    )
    data["recentRuns"] = data["recentRuns"][:50]
    path.write_text(json.dumps(data, indent=2))


async def handle(ws: websockets.WebSocketServerProtocol) -> None:
    session_id = "default"
    conn_id = id(ws)
    log_event(log, "client_connected", conn_id=conn_id)

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError as exc:
            log_event(log, "ws_recv_invalid_json", error=str(exc), raw=raw[:200])
            continue

        kind = msg.get("type", "")
        log_event(log, "ws_recv", type=kind, summary=_summarize(msg))

        try:
            match kind:
                case "attach_observer":
                    session_id = msg.get("sessionId", session_id)

                    async def on_step(step: dict, sid: str = session_id) -> None:
                        obs = _observers.get(sid)
                        count = len(obs.buffer) if obs else 0
                        log_event(
                            log,
                            "step_observed",
                            session_id=sid,
                            count=count,
                            url=step.get("url", "")[:80],
                            action_type=step.get("action", {}).get("type"),
                        )
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
                    log_event(log, "observer_attached", session_id=session_id)
                    await _send(ws, {"type": "observer_attached", "sessionId": session_id})

                case "observe_event":
                    session_id = msg.get("sessionId", session_id)
                    observer = _observers.get(session_id)
                    event = msg.get("event", {})
                    if not observer:
                        log_event(log, "observe_event_no_observer", session_id=session_id)
                        await _send(
                            ws,
                            {"type": "error", "message": f"No observer for session {session_id}"},
                        )
                        continue
                    await observer.ingest(event)

                case "compile_workflow":
                    session_id = msg.get("sessionId", session_id)
                    name = msg.get("name", "Untitled workflow")
                    observer = _observers.get(session_id)
                    buf_len = len(observer.buffer) if observer else 0
                    log_event(log, "compile_workflow", session_id=session_id, name=name, buffer_len=buf_len)
                    if not observer or not observer.buffer:
                        log_event(log, "compile_workflow_empty_buffer", session_id=session_id)
                        await _send(ws, {"type": "error", "message": "No steps to compile"})
                        continue
                    workflow = compile_workflow_from_buffer(name, observer.buffer)
                    wid = workflow["id"]
                    (WORKFLOW_DIR / f"{wid}.json").write_text(json.dumps(workflow, indent=2))
                    log_event(log, "workflow_saved", workflow_id=wid, name=name, steps=buf_len)
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

                case "exa_search":
                    from exa_client import exa_answer

                    request_id = msg.get("requestId", "")
                    query = msg.get("query", "")
                    log_event(log, "exa_search", request_id=request_id, query=query[:80])
                    try:
                        answer = await exa_answer(query)
                        log_event(log, "exa_search_ok", request_id=request_id, answer_len=len(answer))
                        await _send(
                            ws,
                            {
                                "type": "exa_search_result",
                                "requestId": request_id,
                                "answer": answer,
                            },
                        )
                    except Exception as exc:
                        log_event(log, "exa_search_error", request_id=request_id, error=str(exc))
                        await _send(
                            ws,
                            {
                                "type": "exa_search_result",
                                "requestId": request_id,
                                "error": str(exc),
                            },
                        )

                case "execute_workflow":
                    workflow_id = msg.get("workflowId", "")
                    wf = _load_workflow(workflow_id)
                    log_event(log, "execute_workflow", workflow_id=workflow_id, found=wf is not None)
                    if not wf:
                        await _send(ws, {"type": "error", "message": "Workflow not found"})
                        continue
                    await _cancel_playwright_execution(conn_id)
                    if _use_playwright():
                        task = asyncio.create_task(
                            _run_playwright_workflow(ws, conn_id, wf, msg.get("params", {}))
                        )
                        _playwright_tasks[conn_id] = task
                    else:
                        _executors[conn_id] = PolicyExecutor(wf, msg.get("params", {}))
                        _exec_meta[conn_id] = {
                            "t0": time.time(),
                            "workflowId": workflow_id,
                            "workflowName": wf.get("name", ""),
                            "params": msg.get("params", {}),
                            "steps": 0,
                            "actions_executed": [],
                            "last_url": "",
                            "last_title": "",
                            "last_tree": None,
                        }
                        await _send(
                            ws,
                            {
                                "type": "execute_started",
                                "workflowId": workflow_id,
                                "backend": "webkit",
                            },
                        )

                case "execute_state":
                    # Legacy WebKit ping-pong path (kept for compatibility; Playwright runs server-side)
                    executor = _executors.get(conn_id)
                    meta = _exec_meta.get(conn_id, {})
                    if conn_id in _playwright_tasks and not _playwright_tasks[conn_id].done():
                        continue
                    if not executor:
                        log_event(log, "execute_state_no_executor", conn_id=conn_id)
                        await _send(ws, {"type": "error", "message": "No active execution"})
                        continue

                    meta["steps"] = meta.get("steps", 0) + 1
                    url = msg.get("url", "")
                    meta["last_url"] = url
                    meta["last_title"] = msg.get("title", "")
                    meta["last_tree"] = msg.get("accessibilityTree")
                    log_event(
                        log,
                        "execute_state",
                        step=meta["steps"],
                        url=url[:80],
                        workflow_id=meta.get("workflowId"),
                    )
                    if meta["steps"] > 25:
                        await _finish_execution(ws, conn_id, meta, executor, reason="max_steps")
                        continue

                    result = await executor.next_action(
                        url,
                        msg.get("title", ""),
                        msg.get("accessibilityTree"),
                        last_action_ok=msg.get("lastActionOk"),
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
                        await _finish_execution(ws, conn_id, meta, executor, reason="done")
                    else:
                        action = result.get("action", {})
                        meta.setdefault("actions_executed", []).append(action)
                        log_event(
                            log,
                            "execute_action",
                            action_type=result.get("action", {}).get("type"),
                            tier=result.get("tier"),
                        )
                        await _send(
                            ws,
                            {
                                "type": "execute_action",
                                "action": result.get("action", {}),
                                "tier": result.get("tier", 1),
                                "tokens": result.get("tokens", 0),
                                "sim": result.get("sim"),
                                "step": result.get("step"),
                                "total": result.get("total"),
                            },
                        )

                case "cancel_execute":
                    await _cancel_playwright_execution(conn_id)
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
                    log_event(log, "list_workflows", count=len(workflows))
                    await _send(ws, {"type": "workflows_list", "workflows": workflows})

                case "delete_all_workflows":
                    deleted = 0
                    for p in WORKFLOW_DIR.glob("*.json"):
                        p.unlink(missing_ok=True)
                        deleted += 1
                    await _cancel_playwright_execution(conn_id)
                    log_event(log, "delete_all_workflows", count=deleted)
                    await _send(ws, {"type": "workflows_deleted", "count": deleted})
                    await _send(ws, {"type": "workflows_list", "workflows": []})

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

                case "client_log":
                    log_event(
                        log,
                        f"swift:{msg.get('component', 'app')}/{msg.get('message', '')}",
                        **(msg.get("data") or {}),
                    )
                    await _send(ws, {"type": "client_log_ack"})

                case _:
                    log_event(log, "unknown_message_type", type=kind)
                    await _send(ws, {"type": "error", "message": f"unknown type: {kind}"})
        except Exception as exc:
            log.error("handler_exception type=%s\n%s", kind, traceback.format_exc())
            detail = str(exc) or "internal engine error"
            await _send(ws, {"type": "error", "message": detail[:200]})


async def main() -> None:
    port = int(os.environ.get("OPENHIVE_ENGINE_PORT", "8765"))
    keys = _keys_env()
    log_event(log, "engine_starting", port=port, keys=keys, log_dir=str(LOG_DIR))
    async with websockets.serve(handle, "127.0.0.1", port):
        log_event(log, "engine_listening", port=port, host="127.0.0.1")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
