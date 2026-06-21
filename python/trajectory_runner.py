"""Run proven Google Flights trajectories against the Swift app's WKWebView."""

from __future__ import annotations

import asyncio
import time
from typing import Any, Awaitable, Callable

from agent_llm import choose_next_action
from smoke.run_local_browser_trace_gate import reached_results, scripted_action

SendFn = Callable[[dict[str, Any]], Awaitable[None]]


def candidate_center(candidate: dict[str, Any]) -> tuple[float, float] | None:
    bbox = candidate.get("bbox") or {}
    width = bbox.get("width") or 0
    height = bbox.get("height") or 0
    if width <= 0 or height <= 0:
        return None
    return bbox.get("x", 0) + width / 2, bbox.get("y", 0) + height / 2


def to_swift_action(action: dict[str, Any], candidates: list[dict[str, Any]]) -> dict[str, Any]:
    """Convert scripted_action output to BrowserToolExecutor payload."""
    kind = action.get("action") or action.get("type") or "click"

    if kind == "navigate":
        url = action.get("value") or action.get("url") or ""
        return {"type": "navigate", "url": url}

    if kind == "search":
        return {"type": "search", "value": action.get("value") or action.get("query") or ""}

    if kind == "new_tab":
        return {"type": "new_tab", "url": action.get("value") or action.get("url") or "about:blank"}

    if kind == "scroll":
        return {"type": "scroll", "value": action.get("value") or action.get("direction") or "down"}

    if kind == "select":
        payload: dict[str, Any] = {"type": "select", "value": action.get("value") or ""}
        ref = action.get("ref")
        if ref:
            payload["ref"] = ref
        return payload

    if kind in {"go_back", "go_forward", "reload"}:
        return {"type": kind}

    if kind == "switch_tab":
        payload = {"type": "switch_tab"}
        if action.get("index") is not None:
            payload["index"] = action["index"]
        if action.get("value"):
            payload["value"] = action["value"]
        return payload

    if kind == "close_tab":
        return {"type": "close_tab"}

    if kind in {"hover", "check", "uncheck", "dblclick", "double_click", "scroll_into_view", "scrollintoview", "click_option", "wait", "wait_for", "extract", "evaluate", "eval", "upload"}:
        payload: dict[str, Any] = {"type": kind if kind != "double_click" else "dblclick"}
        for key in ("ref", "selector", "value", "text", "timeout", "path", "script", "index"):
            if action.get(key) is not None:
                payload[key] = action[key]
        if kind == "eval":
            payload["type"] = "evaluate"
        if kind == "wait_for":
            payload["type"] = "wait"
        if kind == "scrollintoview":
            payload["type"] = "scroll_into_view"
        return payload

    if kind == "click_xy":
        return {
            "type": "click",
            "x": float(action["x"]),
            "y": float(action["y"]),
            "text": str(action.get("value") or "Done"),
        }

    if kind == "press":
        return {"type": "press", "value": action.get("value") or "Enter"}

    if kind == "mcp_call":
        return {
            "type": "mcp_call",
            "server": action.get("server") or action.get("namespace") or "",
            "tool": action.get("tool") or "",
            "arguments": action.get("arguments") or action.get("args") or {},
        }

    if kind == "done":
        return {"type": "done"}

    ref = action.get("ref")
    candidate = next((c for c in candidates if c.get("ref") == ref), None)
    label = (
        candidate.get("text")
        or candidate.get("ariaLabel")
        or candidate.get("placeholder")
        or ""
        if candidate
        else ""
    )

    if kind == "type":
        payload: dict[str, Any] = {"type": "type", "value": action.get("value") or ""}
        if ref:
            payload["ref"] = ref
        if label:
            payload["text"] = label
        if candidate and candidate.get("selector"):
            payload["selector"] = candidate["selector"]
        if candidate:
            center = candidate_center(candidate)
            if center:
                payload["x"], payload["y"] = center
        return payload

    if kind in {"click", "click_date", "next_month"}:
        payload = {"type": "click", "text": label or kind}
        if ref:
            payload["ref"] = ref
        if candidate and candidate.get("selector"):
            payload["selector"] = candidate["selector"]
        if candidate:
            center = candidate_center(candidate)
            if center:
                payload["x"], payload["y"] = center
        return payload

    return {"type": "click", "text": label or str(kind)}


class TrajectorySession:
    def __init__(self, send: SendFn) -> None:
        self._send = send
        self._state_event = asyncio.Event()
        self._last_state: dict[str, Any] = {}
        self._running = False

    @property
    def is_running(self) -> bool:
        return self._running

    def on_execute_state(self, msg: dict[str, Any]) -> bool:
        """Return True if consumed."""
        if not self._running:
            return False
        tree = msg.get("accessibilityTree") or {}
        candidates = msg.get("candidates") or tree.get("candidates") or []
        self._last_state = {
            "url": msg.get("url", ""),
            "title": msg.get("title", ""),
            "text": msg.get("pageText", ""),
            "candidates": candidates,
            "lastActionOk": msg.get("lastActionOk"),
            "lastActionDetail": msg.get("lastActionDetail"),
        }
        self._state_event.set()
        return True

    async def _wait_state(self, timeout: float = 20.0) -> dict[str, Any]:
        """Wait for the next execute_state from Swift. Do not clear an already-set event."""
        if not self._state_event.is_set():
            await asyncio.wait_for(self._state_event.wait(), timeout=timeout)
        self._state_event.clear()
        return self._last_state

    async def _maybe_compile_flight_demo(
        self, task: dict[str, str], history: list[dict[str, Any]], success: bool
    ) -> None:
        if not success or not task.get("flightDemoLearn"):
            return
        from flight_demo import install_hardcoded_skill

        skill_id = await install_hardcoded_skill()
        await self._send(
            {
                "type": "flight_demo_saved",
                "skillId": skill_id,
                "message": "Flight workflow learned — run again for fast MDP replay",
            }
        )

    def _run_mode(self, task: dict[str, str]) -> str:
        if task.get("flightDemoReplay"):
            return "replay"
        if task.get("flightDemoLearn"):
            return "learning"
        return "trajectory"

    def _history_selected_text(
        self,
        raw: dict[str, Any],
        swift_action: dict[str, Any],
        candidates: list[dict[str, Any]],
    ) -> str:
        ref = raw.get("ref")
        if ref:
            candidate = next((c for c in candidates if c.get("ref") == ref), None)
            if candidate:
                label = (
                    candidate.get("text")
                    or candidate.get("ariaLabel")
                    or candidate.get("placeholder")
                    or ""
                )
                if label:
                    return str(label)
        return str(raw.get("value") or swift_action.get("text") or "")

    async def _step_delay(self, task: dict[str, str], swift_action: dict[str, Any]) -> None:
        kind = swift_action.get("type")
        if task.get("flightDemoReplay"):
            await asyncio.sleep(1.0 if kind == "navigate" else 0.4)
            return
        if task.get("flightDemoLearn"):
            base = 2.5 if kind == "navigate" else 1.8
            await asyncio.sleep(base)
            return
        await asyncio.sleep(1.0 if kind == "navigate" else 0.8)

    def _state_timeout(self, task: dict[str, str]) -> float:
        if task.get("flightDemoLearn"):
            return 60.0
        if task.get("flightDemoReplay"):
            return 35.0
        return 25.0

    async def _pick_action(
        self,
        task: dict[str, str],
        summary: dict[str, Any],
        candidates: list[dict[str, Any]],
        history: list[dict[str, Any]],
        step: int,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        if (
            task.get("flightDemoLearn")
            or task.get("flightDemoReplay")
            or (task.get("origin") and task.get("destination"))
        ):
            raw = scripted_action(task, candidates, history)
            return raw, {"source": "scripted", "model": "scripted-google-flights-expert"}
        return await choose_next_action(task, summary, candidates, history, step)

    async def run(self, task: dict[str, str], *, max_steps: int = 12) -> dict[str, Any]:
        from flight_demo import DEMO_SKILL_ID

        origin = task.get("origin", "BOS")
        destination = task.get("destination", "SFO")
        is_flight_demo = bool(task.get("flightDemoLearn") or task.get("flightDemoReplay"))
        if is_flight_demo:
            max_steps = max(max_steps, 24)
        state_timeout = self._state_timeout(task)
        run_mode = self._run_mode(task)
        self._running = True
        self._state_event.clear()
        history: list[dict[str, Any]] = []
        t0 = time.time()

        try:
            started: dict[str, Any] = {
                "type": "execute_started",
                "backend": "webkit",
                "workflowName": f"{origin}→{destination}",
            }
            if task.get("flightDemoReplay"):
                started["skillId"] = DEMO_SKILL_ID
            await self._send(started)

            await self._send(
                {
                    "type": "execute_action",
                    "backend": "webkit",
                    "action": {
                        "type": "navigate",
                        "url": "https://www.google.com/travel/flights",
                    },
                    "step": 0,
                    "total": max_steps,
                }
            )
            if task.get("flightDemoReplay"):
                await asyncio.sleep(2.0)
            elif task.get("flightDemoLearn"):
                await asyncio.sleep(4.0)
            else:
                await asyncio.sleep(4.0)
            state = await self._wait_state(timeout=state_timeout)

            for step in range(max_steps):
                candidates = state.get("candidates") or []
                summary = {
                    "url": state.get("url", ""),
                    "title": state.get("title", ""),
                    "text": state.get("text", ""),
                }
                if step > 0 and reached_results(summary):
                    elapsed = round(time.time() - t0, 1)
                    await self._maybe_compile_flight_demo(task, history, True)
                    await self._send(
                        {
                            "type": "trajectory_complete",
                            "success": True,
                            "steps": step,
                            "finalUrl": state.get("url", ""),
                            "reason": "results_detected",
                            "elapsedSec": elapsed,
                            "flightDemoLearn": bool(task.get("flightDemoLearn")),
                            "flightDemoReplay": bool(task.get("flightDemoReplay")),
                        }
                    )
                    await self._send({"type": "execute_done", "hudStatus": "ok"})
                    return {
                        "success": True,
                        "steps": step,
                        "finalUrl": state.get("url", ""),
                        "elapsedSec": elapsed,
                    }

                raw, meta = await self._pick_action(task, summary, candidates, history, step)
                kind = raw.get("action") or raw.get("type") or "click"

                await self._send(
                    {
                        "type": "agent_step",
                        "step": step + 1,
                        "provider": meta.get("provider") or meta.get("source"),
                        "model": meta.get("model"),
                        "action": kind,
                        "ref": raw.get("ref"),
                        "mode": run_mode,
                    }
                )
                if is_flight_demo:
                    await self._send(
                        {
                            "type": "mdp_step",
                            "skillId": DEMO_SKILL_ID,
                            "stateId": str(step),
                            "nextStateId": str(step + 1),
                            "action": kind,
                            "tier": 1,
                            "step": step + 1,
                            "total": max_steps,
                        }
                    )

                if kind == "done":
                    elapsed = round(time.time() - t0, 1)
                    await self._maybe_compile_flight_demo(task, history, True)
                    await self._send(
                        {
                            "type": "trajectory_complete",
                            "success": True,
                            "steps": step + 1,
                            "finalUrl": state.get("url", ""),
                            "reason": "agent_done",
                            "elapsedSec": elapsed,
                            "flightDemoLearn": bool(task.get("flightDemoLearn")),
                            "flightDemoReplay": bool(task.get("flightDemoReplay")),
                        }
                    )
                    await self._send({"type": "execute_done", "hudStatus": "ok"})
                    return {"success": True, "steps": step + 1, "finalUrl": state.get("url", ""), "elapsedSec": elapsed}

                swift_action = to_swift_action(raw, candidates)
                await self._send(
                    {
                        "type": "execute_action",
                        "backend": "webkit",
                        "action": swift_action,
                        "step": step + 1,
                        "total": max_steps,
                        "tier": 3 if meta.get("source") == "llm" else 1,
                        "mode": meta.get("source", run_mode),
                    }
                )

                await self._step_delay(task, swift_action)
                state = await self._wait_state(timeout=state_timeout)
                if state.get("lastActionOk") is not False:
                    stored = dict(raw)
                    if stored.get("action") and not stored.get("type"):
                        stored["type"] = stored["action"]
                    history.append(
                        {
                            "action": stored,
                            "provider": meta.get("source"),
                            "selectedText": self._history_selected_text(raw, swift_action, candidates),
                            "url": state.get("url", ""),
                        }
                    )

                if is_flight_demo:
                    elapsed_ms = int((time.time() - t0) * 1000)
                    await self._send(
                        {
                            "type": "run_metric",
                            "tokens": 0 if task.get("flightDemoReplay") else 120,
                            "tier": 1,
                            "elapsedMs": elapsed_ms,
                            "runType": "execute" if task.get("flightDemoReplay") else "agent",
                            "workflowName": f"{origin}→{destination}",
                        }
                    )

            elapsed = round(time.time() - t0, 1)
            success = reached_results(
                {
                    "url": state.get("url", ""),
                    "title": state.get("title", ""),
                    "text": state.get("text", ""),
                }
            )
            await self._maybe_compile_flight_demo(task, history, success)
            await self._send(
                {
                    "type": "trajectory_complete",
                    "success": success,
                    "steps": max_steps,
                    "finalUrl": state.get("url", ""),
                    "reason": "results_detected" if success else "max_steps",
                    "elapsedSec": elapsed,
                    "flightDemoLearn": bool(task.get("flightDemoLearn")),
                    "flightDemoReplay": bool(task.get("flightDemoReplay")),
                }
            )
            await self._send({"type": "execute_done", "hudStatus": "ok" if success else "partial"})
            return {
                "success": success,
                "steps": max_steps,
                "finalUrl": state.get("url", ""),
                "elapsedSec": elapsed,
            }
        except asyncio.TimeoutError:
            if task.get("flightDemoLearn"):
                try:
                    from flight_demo import install_hardcoded_skill

                    skill_id = await install_hardcoded_skill()
                    await self._send(
                        {
                            "type": "flight_demo_saved",
                            "skillId": skill_id,
                            "message": "Saved backup flight MDP — run again for fast replay",
                        }
                    )
                except Exception:
                    pass
            await self._send(
                {
                    "type": "trajectory_complete",
                    "success": False,
                    "reason": "timeout",
                    "steps": len(history),
                    "flightDemoLearn": bool(task.get("flightDemoLearn")),
                }
            )
            await self._send({"type": "execute_done", "hudStatus": "partial"})
            await self._send({"type": "error", "message": "Trajectory timed out waiting for page state"})
            return {"success": False, "reason": "timeout", "steps": len(history)}
        except Exception as exc:
            await self._send({"type": "error", "message": str(exc)[:200]})
            return {"success": False, "error": str(exc), "steps": len(history)}
        finally:
            self._running = False
