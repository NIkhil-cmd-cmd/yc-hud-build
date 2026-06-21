"""Shared agent loop — LLM decides actions, Swift executes in the current WKWebView tab."""

from __future__ import annotations

import asyncio
import time
from typing import Any, Awaitable, Callable

from agent_llm import choose_next_action
from smoke.run_local_browser_trace_gate import reached_results
from trajectory_runner import TrajectorySession, to_swift_action

SendFn = Callable[[dict[str, Any]], Awaitable[None]]


class AgentTaskSession(TrajectorySession):
    """Generic goal-driven agent (any website). Uses LLM + current page state."""

    async def run(
        self,
        task: dict[str, Any],
        *,
        max_steps: int = 20,
        start_url: str | None = None,
    ) -> dict[str, Any]:
        goal = task.get("goal") or task.get("name") or "Complete the task"
        self._running = True
        history: list[dict[str, Any]] = []
        t0 = time.time()

        try:
            await self._send(
                {
                    "type": "execute_started",
                    "backend": "webkit",
                    "workflowName": str(goal)[:80],
                    "agentMode": "in-tab",
                }
            )

            if start_url:
                await self._send(
                    {
                        "type": "execute_action",
                        "backend": "webkit",
                        "action": {"type": "navigate", "url": start_url},
                        "step": 0,
                        "total": max_steps,
                        "tier": 3,
                        "mode": "agent",
                    }
                )
                await asyncio.sleep(0.8)
                state = await self._wait_state()
            else:
                try:
                    state = await self._wait_state(timeout=5)
                except asyncio.TimeoutError:
                    state = {"url": "", "title": "", "text": "", "candidates": []}

            for step in range(max_steps):
                candidates = state.get("candidates") or []
                summary = {
                    "url": state.get("url", ""),
                    "title": state.get("title", ""),
                    "text": (state.get("text") or "")[:5000],
                }

                # Flight-specific terminal check
                if task.get("origin") and task.get("destination") and step > 0 and reached_results(summary):
                    return await self._finish(True, step, state, t0, "results_detected")

                raw, meta = await choose_next_action(task, summary, candidates, history, step)
                kind = raw.get("action") or raw.get("type") or "click"

                usage = meta.get("usage") or {}
                total_tokens = usage.get("total_tokens") or 0
                if total_tokens:
                    await self._send(
                        {
                            "type": "run_metric",
                            "tokens": total_tokens,
                            "tier": 3 if meta.get("source") == "llm" else 1,
                            "elapsedMs": int((time.time() - t0) * 1000),
                        }
                    )

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
                    return await self._finish(True, step + 1, state, t0, "agent_done")

                if kind == "mcp_call":
                    swift_action = {
                        "type": "mcp_call",
                        "server": raw.get("server") or raw.get("namespace") or "",
                        "tool": raw.get("tool") or "",
                        "arguments": raw.get("arguments") or raw.get("args") or {},
                    }
                elif kind == "navigate":
                    url = raw.get("value") or raw.get("url") or ""
                    swift_action = {"type": "navigate", "url": url}
                elif kind in {"search", "new_tab", "scroll", "select", "go_back", "go_forward", "reload", "switch_tab", "close_tab",
                              "hover", "check", "uncheck", "dblclick", "double_click", "wait", "wait_for",
                              "extract", "evaluate", "eval", "upload", "click_option", "scroll_into_view", "scrollintoview"}:
                    swift_action = to_swift_action(raw, candidates)
                else:
                    swift_action = to_swift_action(raw, candidates)

                await self._send(
                    {
                        "type": "execute_action",
                        "backend": "webkit",
                        "action": swift_action,
                        "step": step + 1,
                        "total": max_steps,
                        "tier": 3 if meta.get("source") == "llm" else 1,
                        "mode": meta.get("source", "agent"),
                    }
                )

                await asyncio.sleep(0.4 if swift_action.get("type") == "navigate" else 0.2)
                state = await self._wait_state(timeout=30)
                if state.get("lastActionOk") is not False:
                    history.append(
                        {
                            "step": step,
                            "action": raw,
                            "provider": meta.get("source"),
                            "selectedText": raw.get("value") or swift_action.get("text") or "",
                            "url": state.get("url", ""),
                        }
                    )

            return await self._finish(
                reached_results(
                    {
                        "url": state.get("url", ""),
                        "title": state.get("title", ""),
                        "text": state.get("text", ""),
                    }
                )
                if task.get("origin")
                else False,
                max_steps,
                state,
                t0,
                "max_steps",
            )
        except asyncio.TimeoutError:
            await self._send({"type": "error", "message": "Agent timed out waiting for page state"})
            return {"success": False, "reason": "timeout", "steps": len(history)}
        except Exception as exc:
            await self._send({"type": "error", "message": str(exc)[:200]})
            return {"success": False, "error": str(exc), "steps": len(history)}
        finally:
            self._running = False

    async def _finish(
        self,
        success: bool,
        steps: int,
        state: dict[str, Any],
        t0: float,
        reason: str,
    ) -> dict[str, Any]:
        elapsed = round(time.time() - t0, 1)
        await self._send(
            {
                "type": "trajectory_complete",
                "success": success,
                "steps": steps,
                "finalUrl": state.get("url", ""),
                "reason": reason,
                "elapsedSec": elapsed,
            }
        )
        await self._send({"type": "execute_done", "hudStatus": "ok" if success else "partial"})
        return {
            "success": success,
            "steps": steps,
            "finalUrl": state.get("url", ""),
            "elapsedSec": elapsed,
            "reason": reason,
        }
