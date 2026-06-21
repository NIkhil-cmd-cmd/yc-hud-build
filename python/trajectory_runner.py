"""Run proven Google Flights trajectories against the Swift app's WKWebView."""

from __future__ import annotations

import asyncio
import time
from typing import Any, Awaitable, Callable

from agent_llm import choose_next_action
from smoke.run_local_browser_trace_gate import reached_results

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

    if kind == "click_xy":
        return {
            "type": "click",
            "x": float(action["x"]),
            "y": float(action["y"]),
            "text": str(action.get("value") or "Done"),
        }

    if kind == "press":
        return {"type": "press", "value": action.get("value") or "Enter"}

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
        if candidate:
            center = candidate_center(candidate)
            if center:
                payload["x"], payload["y"] = center
        return payload

    if kind in {"click", "click_date", "next_month"}:
        payload = {"type": "click", "text": label or kind}
        if ref:
            payload["ref"] = ref
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
        }
        self._state_event.set()
        return True

    async def _wait_state(self, timeout: float = 20.0) -> dict[str, Any]:
        self._state_event.clear()
        await asyncio.wait_for(self._state_event.wait(), timeout=timeout)
        return self._last_state

    async def run(self, task: dict[str, str], *, max_steps: int = 12) -> dict[str, Any]:
        origin = task["origin"]
        destination = task["destination"]
        depart_date = task["departDate"]
        self._running = True
        history: list[dict[str, Any]] = []
        t0 = time.time()

        try:
            await self._send(
                {
                    "type": "execute_started",
                    "backend": "webkit",
                    "workflowName": f"{origin}→{destination}",
                }
            )
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
            await asyncio.sleep(4)
            state = await self._wait_state()

            for step in range(max_steps):
                candidates = state.get("candidates") or []
                summary = {
                    "url": state.get("url", ""),
                    "title": state.get("title", ""),
                    "text": state.get("text", ""),
                }
                if step > 0 and reached_results(summary):
                    elapsed = round(time.time() - t0, 1)
                    await self._send(
                        {
                            "type": "trajectory_complete",
                            "success": True,
                            "steps": step,
                            "finalUrl": state.get("url", ""),
                            "reason": "results_detected",
                            "elapsedSec": elapsed,
                        }
                    )
                    await self._send({"type": "execute_done", "hudStatus": "ok"})
                    return {
                        "success": True,
                        "steps": step,
                        "finalUrl": state.get("url", ""),
                        "elapsedSec": elapsed,
                    }

                raw, meta = await choose_next_action(task, summary, candidates, history, step)
                kind = raw.get("action") or raw.get("type") or "click"

                await self._send(
                    {
                        "type": "agent_step",
                        "step": step + 1,
                        "provider": meta.get("provider") or meta.get("source"),
                        "model": meta.get("model"),
                        "action": kind,
                        "ref": raw.get("ref"),
                    }
                )

                if kind == "done":
                    elapsed = round(time.time() - t0, 1)
                    await self._send(
                        {
                            "type": "trajectory_complete",
                            "success": True,
                            "steps": step + 1,
                            "finalUrl": state.get("url", ""),
                            "reason": "agent_done",
                            "elapsedSec": elapsed,
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
                        "mode": meta.get("source", "trajectory"),
                    }
                )

                await asyncio.sleep(1.0 if swift_action.get("type") == "navigate" else 0.8)
                state = await self._wait_state(timeout=25)
                history.append(
                    {
                        "action": raw,
                        "provider": meta.get("source"),
                        "selectedText": raw.get("value") or swift_action.get("text") or "",
                        "url": state.get("url", ""),
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
            await self._send(
                {
                    "type": "trajectory_complete",
                    "success": success,
                    "steps": max_steps,
                    "finalUrl": state.get("url", ""),
                    "reason": "results_detected" if success else "max_steps",
                    "elapsedSec": elapsed,
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
            await self._send(
                {
                    "type": "trajectory_complete",
                    "success": False,
                    "reason": "timeout",
                    "steps": len(history),
                }
            )
            await self._send({"type": "error", "message": "Trajectory timed out waiting for page state"})
            return {"success": False, "reason": "timeout", "steps": len(history)}
        except Exception as exc:
            await self._send({"type": "error", "message": str(exc)[:200]})
            return {"success": False, "error": str(exc), "steps": len(history)}
        finally:
            self._running = False
