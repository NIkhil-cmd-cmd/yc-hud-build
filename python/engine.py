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
from train import build_policy_json, compile_workflow_from_buffer, write_policy_artifact

log = setup_logging("openhive.engine")

APP_SUPPORT = Path.home() / "Library/Application Support/OpenHive"
HARVEST_DIR = APP_SUPPORT / "harvest"
WORKFLOW_DIR = APP_SUPPORT / "workflows"
SKILLS_DIR = APP_SUPPORT / "skills"
MDPS_DIR = APP_SUPPORT / "mdps"
METRICS_DIR = APP_SUPPORT / "metrics"
LOG_DIR = APP_SUPPORT / "logs"
TRACES_DIR = APP_SUPPORT / "traces"
BENCHMARKS_DIR = APP_SUPPORT / "benchmarks"

for d in (HARVEST_DIR, WORKFLOW_DIR, SKILLS_DIR, MDPS_DIR, METRICS_DIR, LOG_DIR, TRACES_DIR, BENCHMARKS_DIR):
    d.mkdir(parents=True, exist_ok=True)

_observers: dict[str, Observer] = {}
_executors: dict[str, PolicyExecutor] = {}
_exec_meta: dict[str, dict[str, Any]] = {}
_playwright_runners: dict[int, PlaywrightRunner] = {}
_playwright_tasks: dict[int, asyncio.Task] = {}
_trajectory_sessions: dict[int, Any] = {}
_agent_prefs: dict[int, dict[str, str]] = {}
_trajectory_tasks: dict[int, asyncio.Task] = {}
_mcp_tools: dict[int, list[dict[str, Any]]] = {}
MAX_WORKFLOW_STEPS = 50


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


def _use_browser_use() -> bool:
    """External Playwright/Chromium via browser-use library (benchmarks only — off by default)."""
    return os.environ.get("OPENHIVE_USE_BROWSER_USE", "0") == "1"


def _in_tab_agent_enabled() -> bool:
    """In-tab WKWebView agent (default Dia path — same snapshot/@ref loop as agent-browser)."""
    from agent_llm import llm_available

    return llm_available()


async def _schedule_agent_task(
    ws: websockets.WebSocketServerProtocol,
    conn_id: int,
    msg: dict[str, Any],
) -> None:
    """Run agent in the current Nook tab (default) or external Chromium when explicitly enabled."""
    from agent_loop import AgentTaskSession
    from agent_llm import llm_available
    from browser_use_runner import browser_use_enabled, run_browser_use_task

    _executors.pop(conn_id, None)
    _exec_meta.pop(conn_id, None)
    goal = (msg.get("goal") or msg.get("task") or "").strip()
    if not goal and isinstance(msg.get("task"), dict):
        goal = msg["task"].get("goal") or ""
    if not goal:
        await _send(ws, {"type": "error", "message": "Agent task requires a goal string"})
        return

    existing = _trajectory_tasks.get(conn_id)
    if existing and not existing.done():
        await _send(ws, {"type": "error", "message": "Agent already running"})
        return

    if browser_use_enabled():
        if not llm_available():
            await _send(
                ws,
                {"type": "error", "message": "OPENAI_API_KEY required for external browser-use agent"},
            )
            return
    elif not llm_available():
        await _send(
            ws,
            {
                "type": "error",
                "message": "No LLM API key — add OPENAI_API_KEY to .env and restart ./scripts/start_engine.sh",
            },
        )
        return

    log_event(
        log,
        "start_agent_received",
        goal=goal[:120],
        conn_id=conn_id,
        backend="browser-use" if browser_use_enabled() else "webkit",
    )
    start_url = msg.get("startUrl") or msg.get("url")
    max_steps = int(msg.get("maxSteps") or os.environ.get("OPENHIVE_AGENT_MAX_STEPS", "40"))
    ctx = msg.get("storageState") if isinstance(msg.get("storageState"), dict) else None
    task = msg.get("task") if isinstance(msg.get("task"), dict) else {"goal": goal}
    if "goal" not in task:
        task["goal"] = goal
    if msg.get("mcpTools"):
        task["mcpTools"] = msg["mcpTools"]
    elif conn_id in _mcp_tools:
        task["mcpTools"] = _mcp_tools[conn_id]
    prefs = _agent_prefs.get(conn_id, {})
    if msg.get("agentProvider"):
        task["agentProvider"] = msg["agentProvider"]
        if msg.get("agentModel"):
            task["agentModel"] = msg["agentModel"]
    elif prefs.get("provider"):
        task["agentProvider"] = prefs["provider"]
        if prefs.get("model"):
            task["agentModel"] = prefs["model"]
    send_fn = lambda payload: _send(ws, payload)

    async def _run_agent() -> None:
        try:
            if browser_use_enabled():
                await run_browser_use_task(
                    send_fn,
                    goal,
                    start_url=start_url,
                    page_url=msg.get("pageUrl") or start_url,
                    page_title=msg.get("pageTitle"),
                    storage_state=ctx,
                    max_steps=max_steps,
                )
            else:
                session = AgentTaskSession(send_fn)
                _trajectory_sessions[conn_id] = session
                await session.run(task, max_steps=max_steps, start_url=start_url)
        finally:
            _trajectory_sessions.pop(conn_id, None)
            _trajectory_tasks.pop(conn_id, None)

    _trajectory_tasks[conn_id] = asyncio.create_task(_run_agent())


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

            await _emit_mdp_step(ws, result)
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


def _engine_config() -> dict[str, Any]:
    return {
        "browserUse": _use_browser_use(),
        "inTabAgent": _in_tab_agent_enabled(),
        "playwright": _use_playwright(),
        "agentModel": os.environ.get("OPENHIVE_AGENT_MODEL", "gpt-4o"),
        "agentMaxSteps": int(os.environ.get("OPENHIVE_AGENT_MAX_STEPS", "40")),
        "keys": _keys_env(),
    }


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
    try:
        await ws.send(json.dumps(payload))
    except websockets.exceptions.ConnectionClosed:
        log_event(log, "ws_send_closed", type=payload.get("type"))


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


def _infer_workflow_category(workflow_id: str, name: str) -> str:
    """Best-effort category for legacy recorded workflows."""
    if workflow_id.startswith("wf_"):
        return "recorded"
    text = f"{workflow_id} {name}".lower()
    rules: list[tuple[str, tuple[str, ...]]] = [
        ("travel", ("flight", "booking", "hotel", "flights")),
        ("search", ("search", "google", "duckduckgo", "youtube")),
        ("dev", ("github", "stackoverflow", "npm", "pypi", "mdn", "crates")),
        ("shopping", ("amazon", "shop")),
        ("news", ("hacker", "reddit", "product hunt", "hn")),
        ("local", ("maps", "yelp", "weather")),
        ("jobs", ("linkedin", "jobs")),
        ("reference", ("wiki", "wikipedia")),
        ("research", ("arxiv", "scholar")),
        ("video", ("youtube",)),
        ("entertainment", ("imdb", "spotify")),
    ]
    for category, keywords in rules:
        if any(k in text for k in keywords):
            return category
    return "other"


def _load_workflow(workflow_id: str) -> dict | None:
    path = WORKFLOW_DIR / f"{workflow_id}.json"
    if not path.exists():
        for p in WORKFLOW_DIR.glob("*.json"):
            if p.name.endswith("_policy.json"):
                continue
            data = json.loads(p.read_text())
            if data.get("id") == workflow_id:
                return data
        # Fall back to MDP storage
        mdp_path = MDPS_DIR / f"{workflow_id}.json"
        if mdp_path.exists():
            return json.loads(mdp_path.read_text())
        return None
    return json.loads(path.read_text())


def _load_skill_workflow(skill_id: str) -> dict | None:
    """Load executable workflow from skill → MDP chain."""
    from task_index import load_mdp, load_skill

    skill = load_skill(skill_id)
    if skill:
        mdp_id = skill.get("mdpId", skill_id)
        mdp = load_mdp(mdp_id)
        if mdp:
            wf = dict(mdp)
            wf["id"] = skill_id
            wf["name"] = skill.get("name", mdp.get("name", skill_id))
            return wf
    return _load_workflow(skill_id)


async def _emit_mdp_step(ws: websockets.WebSocketServerProtocol, result: dict[str, Any]) -> None:
    if result.get("stateId") is None and result.get("nextStateId") is None:
        return
    action = result.get("action") or {}
    await _send(
        ws,
        {
            "type": "mdp_step",
            "skillId": result.get("skillId", ""),
            "stateId": result.get("stateId", ""),
            "nextStateId": result.get("nextStateId", ""),
            "action": action.get("type", ""),
            "tier": result.get("tier", 1),
            "step": result.get("step"),
            "total": result.get("total"),
        },
    )


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

    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError as exc:
                log_event(log, "ws_recv_invalid_json", error=str(exc), raw=raw[:200])
                continue

            kind = msg.get("type", "")
            log_event(log, "ws_recv", type=kind, summary=_summarize(msg))

            try:
                session_id = await _dispatch_message(ws, conn_id, session_id, msg, kind)
            except websockets.exceptions.ConnectionClosed:
                log_event(log, "client_disconnected", conn_id=conn_id, during=kind)
                break
            except Exception as exc:
                log.error("handler_exception type=%s\n%s", kind, traceback.format_exc())
                detail = str(exc) or "internal engine error"
                await _send(ws, {"type": "error", "message": detail[:200]})
    except websockets.exceptions.ConnectionClosedOK:
        log_event(log, "client_disconnected", conn_id=conn_id, reason="going_away")
    except websockets.exceptions.ConnectionClosedError:
        log_event(log, "client_disconnected", conn_id=conn_id, reason="abrupt")
    finally:
        _trajectory_tasks.pop(conn_id, None)
        _trajectory_sessions.pop(conn_id, None)
        _executors.pop(conn_id, None)
        _exec_meta.pop(conn_id, None)
        await _cancel_playwright_execution(conn_id)


async def _dispatch_message(
    ws: websockets.WebSocketServerProtocol,
    conn_id: int,
    session_id: str,
    msg: dict[str, Any],
    kind: str,
) -> str:
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
                    await _send(
                        ws,
                        {
                            "type": "observer_attached",
                            "sessionId": session_id,
                            "browserUse": _use_browser_use(),
                            "engineConfig": _engine_config(),
                        },
                    )

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
                        return session_id
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
                        return session_id
                    workflow = compile_workflow_from_buffer(name, observer.buffer)
                    wid = workflow["id"]
                    (WORKFLOW_DIR / f"{wid}.json").write_text(json.dumps(workflow, indent=2))
                    policy = build_policy_json([{"harvest": observer.buffer, "success": True}])
                    write_policy_artifact(WORKFLOW_DIR / f"{wid}_policy.json", policy)
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
                        return session_id
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

                case "agent_action":
                    from agent_browser import agent_playwright_enabled, perform_action

                    request_id = msg.get("requestId", "")
                    if not agent_playwright_enabled():
                        await _send(
                            ws,
                            {
                                "type": "agent_action_result",
                                "requestId": request_id,
                                "ok": False,
                                "error": "Playwright agent disabled",
                            },
                        )
                        return session_id
                    action = msg.get("action") or {}
                    page_url = msg.get("url") or ""
                    log_event(
                        log,
                        "agent_action",
                        request_id=request_id,
                        action_type=action.get("type"),
                        url=page_url[:80],
                    )
                    try:
                        result = await perform_action(action, url=page_url or None)
                        await _send(
                            ws,
                            {
                                "type": "agent_action_result",
                                "requestId": request_id,
                                "ok": result["ok"],
                                "detail": result["detail"],
                                "url": result.get("url", ""),
                                "title": result.get("title", ""),
                            },
                        )
                    except Exception as exc:
                        log_event(log, "agent_action_error", request_id=request_id, error=str(exc))
                        await _send(
                            ws,
                            {
                                "type": "agent_action_result",
                                "requestId": request_id,
                                "ok": False,
                                "error": str(exc),
                            },
                        )

                case "execute_workflow":
                    workflow_id = msg.get("workflowId", "")
                    wf = _load_workflow(workflow_id)
                    log_event(log, "execute_workflow", workflow_id=workflow_id, found=wf is not None)
                    if not wf:
                        await _send(ws, {"type": "error", "message": "Workflow not found"})
                        return session_id
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
                    traj = _trajectory_sessions.get(conn_id)
                    if traj is not None and traj.is_running:
                        traj.on_execute_state(msg)
                        return session_id

                    # Legacy WebKit ping-pong path (kept for compatibility; Playwright runs server-side)
                    executor = _executors.get(conn_id)
                    meta = _exec_meta.get(conn_id, {})
                    if conn_id in _playwright_tasks and not _playwright_tasks[conn_id].done():
                        return session_id
                    if not executor:
                        log_event(log, "execute_state_no_executor", conn_id=conn_id)
                        await _send(ws, {"type": "error", "message": "No active execution"})
                        return session_id

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
                    if meta["steps"] > MAX_WORKFLOW_STEPS:
                        await _finish_execution(ws, conn_id, meta, executor, reason="max_steps")
                        return session_id

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
                        await _emit_mdp_step(ws, result)
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
                    traj_task = _trajectory_tasks.pop(conn_id, None)
                    if traj_task and not traj_task.done():
                        traj_task.cancel()
                    _trajectory_sessions.pop(conn_id, None)
                    await _send(ws, {"type": "execute_cancelled"})

                case "start_trajectory":
                    from browser_use_runner import browser_use_enabled, run_flight_trajectory
                    from trajectory_runner import TrajectorySession

                    _executors.pop(conn_id, None)
                    _exec_meta.pop(conn_id, None)
                    task = msg.get("task") or {}
                    required = ("origin", "destination", "departDate")
                    if any(not task.get(k) for k in required):
                        await _send(ws, {"type": "error", "message": "Trajectory task missing origin/destination/departDate"})
                        return session_id
                    existing = _trajectory_tasks.get(conn_id)
                    if existing and not existing.done():
                        await _send(ws, {"type": "error", "message": "Trajectory already running"})
                        return session_id

                    send_fn = lambda payload: _send(ws, payload)
                    ctx = msg.get("storageState") if isinstance(msg.get("storageState"), dict) else None
                    max_steps = int(msg.get("maxSteps") or os.environ.get("OPENHIVE_AGENT_MAX_STEPS", "40"))
                    session = TrajectorySession(send_fn)
                    _trajectory_sessions[conn_id] = session

                    async def _run_trajectory() -> None:
                        try:
                            if browser_use_enabled():
                                _trajectory_sessions.pop(conn_id, None)
                                await run_flight_trajectory(
                                    send_fn,
                                    task,
                                    storage_state=ctx,
                                    page_url=msg.get("pageUrl") or msg.get("startUrl"),
                                    page_title=msg.get("pageTitle"),
                                    max_steps=max_steps,
                                )
                            else:
                                await session.run(task, max_steps=max_steps)
                        finally:
                            _trajectory_sessions.pop(conn_id, None)
                            _trajectory_tasks.pop(conn_id, None)

                    _trajectory_tasks[conn_id] = asyncio.create_task(_run_trajectory())

                case "start_agent":
                    await _schedule_agent_task(ws, conn_id, msg)

                case "cancel_trajectory":
                    traj_task = _trajectory_tasks.pop(conn_id, None)
                    if traj_task and not traj_task.done():
                        traj_task.cancel()
                    _trajectory_sessions.pop(conn_id, None)
                    await _send(ws, {"type": "execute_cancelled"})

                case "match_task":
                    from flight_demo import (
                        is_flight_prompt,
                        match_learn_result,
                        match_replay_result,
                        skill_exists,
                    )
                    from task_index import match_task

                    prompt = (msg.get("prompt") or "").strip()
                    if not prompt:
                        await _send(ws, {"type": "error", "message": "match_task requires prompt"})
                        return session_id
                    if is_flight_prompt(prompt):
                        if skill_exists():
                            result = match_replay_result(prompt)
                        else:
                            result = match_learn_result(prompt)
                    else:
                        result = await match_task(prompt)
                    await _send(ws, {"type": "match_task_result", **result})

                case "confirm_run_skill":
                    skill_id = msg.get("skillId", "")
                    wf = _load_skill_workflow(skill_id)
                    if not wf:
                        await _send(ws, {"type": "error", "message": f"Skill not found: {skill_id}"})
                        return session_id
                    await _cancel_playwright_execution(conn_id)
                    params = msg.get("params") or {}
                    _executors[conn_id] = PolicyExecutor(wf, params)
                    _exec_meta[conn_id] = {
                        "t0": time.time(),
                        "workflowId": skill_id,
                        "workflowName": wf.get("name", ""),
                        "params": params,
                        "skillId": skill_id,
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
                            "workflowId": skill_id,
                            "skillId": skill_id,
                            "backend": "webkit",
                        },
                    )

                case "run_agent":
                    goal = (msg.get("goal") or msg.get("prompt") or "").strip()
                    if not goal:
                        await _send(ws, {"type": "error", "message": "run_agent requires goal"})
                        return session_id
                    await _schedule_agent_task(
                        ws,
                        conn_id,
                        {
                            **msg,
                            "goal": goal,
                            "task": msg.get("task") if isinstance(msg.get("task"), dict) else {"goal": goal},
                        },
                    )

                case "start_plan":
                    from task_orchestrator import create_plan

                    prompt = (msg.get("prompt") or "").strip()
                    if not prompt:
                        await _send(ws, {"type": "error", "message": "start_plan requires prompt"})
                        return session_id
                    plan = await create_plan(prompt)
                    await _send(
                        ws,
                        {
                            "type": "plan_created",
                            "planId": plan["planId"],
                            "subtasks": plan["subtasks"],
                            "prompt": prompt,
                        },
                    )

                case "run_subtask":
                    from task_orchestrator import get_plan, mark_subtask_done, resolve_subtask_execution

                    plan_id = msg.get("planId", "")
                    index = int(msg.get("index", 0))
                    plan = get_plan(plan_id)
                    if not plan:
                        await _send(ws, {"type": "error", "message": "Plan not found"})
                        return session_id
                    subtasks = plan.get("subtasks", [])
                    if index >= len(subtasks):
                        await _send(ws, {"type": "error", "message": "Subtask index out of range"})
                        return session_id
                    subtask = subtasks[index]
                    resolution = await resolve_subtask_execution(subtask)
                    await _send(
                        ws,
                        {
                            "type": "orchestrator_step",
                            "planId": plan_id,
                            "index": index,
                            "subtask": subtask,
                            "resolution": resolution,
                        },
                    )
                    if msg.get("markDone"):
                        updated = mark_subtask_done(plan_id, index, success=msg.get("success", True))
                        if updated:
                            await _send(
                                ws,
                                {
                                    "type": "plan_progress",
                                    "planId": plan_id,
                                    "status": updated.get("status"),
                                    "currentIndex": updated.get("currentIndex"),
                                    "subtasks": updated.get("subtasks"),
                                },
                            )

                case "reinforce_skill":
                    from reinforce_mdp import reinforce_skill

                    skill_id = msg.get("skillId", "")
                    session_id = msg.get("sessionId", "default")
                    observer = _observers.get(session_id)
                    steps = observer.buffer if observer else msg.get("steps", [])
                    if not steps:
                        await _send(ws, {"type": "error", "message": "No harvest steps to reinforce"})
                        return session_id
                    result = await reinforce_skill(skill_id, steps, success=msg.get("success", True))
                    from task_index import rebuild_index
                    from task_buckets import rebuild_buckets

                    await rebuild_index()
                    await rebuild_buckets()
                    await _send(ws, {"type": "skill_reinforced", **result})

                case "list_buckets":
                    from task_buckets import list_buckets_with_skills

                    data = await list_buckets_with_skills()
                    await _send(ws, {"type": "buckets_list", **data})

                case "list_skills":
                    async def _list_skills() -> None:
                        try:
                            from task_index import list_skills

                            skills = [
                                {
                                    "id": s["id"],
                                    "name": s.get("name", s["id"]),
                                    "mdpId": s.get("mdpId"),
                                    "bucketId": s.get("bucketId"),
                                    "stats": s.get("stats", {}),
                                }
                                for s in list_skills()
                            ]
                            await _send(ws, {"type": "skills_list", "skills": skills})
                        except Exception as exc:
                            log.error("list_skills_failed\n%s", traceback.format_exc())
                            await _send(ws, {"type": "error", "message": f"list_skills: {str(exc)[:180]}"})

                    asyncio.create_task(_list_skills())

                case "start_hud_benchmark":
                    from benchmark.hud_browser_compare import run_benchmark

                    async def _bench() -> None:
                        try:
                            await run_benchmark(
                                lambda p: _send(ws, p),
                                prompt=msg.get("prompt"),
                                skill_id=msg.get("skillId"),
                                mode=msg.get("mode", "task"),
                                trace_id=msg.get("traceId"),
                            )
                        except Exception as exc:
                            await _send(ws, {"type": "error", "message": f"benchmark: {exc}"[:180]})

                    asyncio.create_task(_bench())

                case "migrate_skills":
                    await _send(ws, {"type": "skills_migrated", "migrated": 0, "skipped": 0, "cached": True})

                case "list_workflows":
                    workflows = []
                    for p in sorted(WORKFLOW_DIR.glob("*.json")):
                        if p.name.endswith("_policy.json"):
                            continue
                        data = json.loads(p.read_text())
                        wid = data.get("id", p.stem)
                        actions = data.get("actions") or []
                        steps = data.get("steps") or len(actions) or 0
                        category = data.get("category") or _infer_workflow_category(wid, data.get("name", p.stem))
                        workflows.append(
                            {
                                "id": wid,
                                "name": data.get("name", p.stem),
                                "steps": steps,
                                "category": category,
                                "tags": data.get("tags") or [],
                                "seeded": bool(data.get("seeded")),
                            }
                        )
                    log_event(log, "list_workflows", count=len(workflows))
                    await _send(ws, {"type": "workflows_list", "workflows": workflows})

                case "get_workflow":
                    workflow_id = msg.get("workflowId") or msg.get("workflow_id")
                    request_id = msg.get("requestId")
                    wf = _load_workflow(workflow_id) if workflow_id else None
                    await _send(
                        ws,
                        {
                            "type": "workflow_loaded",
                            "requestId": request_id,
                            "workflowId": workflow_id,
                            "workflow": wf,
                            "error": None if wf else f"workflow not found: {workflow_id}",
                        },
                    )

                case "set_agent_model":
                    provider = msg.get("provider") or msg.get("agentProvider")
                    model = msg.get("model") or msg.get("agentModel")
                    if provider:
                        _agent_prefs[conn_id] = {
                            "provider": str(provider),
                            "model": str(model or ""),
                        }
                    await _send(
                        ws,
                        {
                            "type": "agent_model_set",
                            "provider": provider,
                            "model": model,
                        },
                    )

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

                case "mcp_tools_updated":
                    tools = msg.get("tools") or []
                    if isinstance(tools, list):
                        _mcp_tools[conn_id] = [t for t in tools if isinstance(t, dict)]
                    log_event(log, "mcp_tools_updated", count=len(_mcp_tools.get(conn_id, [])))

                case "metric":
                    _append_token_metric(msg)
                    await _send(ws, {"type": "metric_ack", "ok": True})

                case "ping":
                    await _send(
                        ws,
                        {
                            "type": "pong",
                            "browserUse": _use_browser_use(),
                            "playwright": _use_playwright(),
                        },
                    )

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

    return session_id


async def _startup_migrate() -> None:
    try:
        from migrate_workflows_to_skills import migrate

        result = await migrate()
        log_event(log, "startup_migrate", **result)
    except Exception as exc:
        log.error("startup_migrate_failed\n%s", traceback.format_exc())


async def main() -> None:
    port = int(os.environ.get("OPENHIVE_ENGINE_PORT", "8765"))
    keys = _keys_env()
    log_event(log, "engine_starting", port=port, keys=keys, log_dir=str(LOG_DIR))
    await _startup_migrate()
    async with websockets.serve(handle, "127.0.0.1", port):
        log_event(log, "engine_listening", port=port, host="127.0.0.1", browser_use=_use_browser_use())
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
