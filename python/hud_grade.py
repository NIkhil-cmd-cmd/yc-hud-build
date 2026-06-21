"""Grade live OpenHive browser executions via HUD task templates."""

from __future__ import annotations

import json
import re
from typing import Any

from hud.environment.server import TaskRunner

from hud_env import FlightParams, env
from log_config import log_event, setup_logging

log = setup_logging("openhive.hud_grade")

DEFAULT_FLIGHT = FlightParams(origin="SFO", destination="JFK", date="2026-07-15")


def _task_id_for_workflow(name: str) -> str:
    lower = name.lower()
    if "flight" in lower or "travel" in lower or "google" in lower:
        return "book_flight"
    return "book_flight"


def _resolve_flight_params(outcome: dict[str, Any]) -> FlightParams:
    raw = outcome.get("params") or {}
    origin = str(raw.get("origin") or raw.get("from") or "").strip().upper()
    destination = str(raw.get("destination") or raw.get("to") or "").strip().upper()
    date = str(raw.get("date") or raw.get("departure") or "").strip()

    text = " ".join(
        [
            outcome.get("workflowName", ""),
            outcome.get("url", ""),
            outcome.get("title", ""),
            json.dumps(outcome.get("actionsExecuted") or [], default=str),
        ]
    ).upper()

    if not origin:
        m = re.search(r"\b([A-Z]{3})\s*(?:to|->|-)\s*([A-Z]{3})\b", text)
        if m:
            origin, destination = m.group(1), m.group(2)

    if not date:
        m = re.search(r"\b(20\d{2}-\d{2}-\d{2})\b", text)
        if m:
            date = m.group(1)

    return FlightParams(
        origin=origin or DEFAULT_FLIGHT.origin,
        destination=destination or DEFAULT_FLIGHT.destination,
        date=date or DEFAULT_FLIGHT.date,
    )


def _build_answer(outcome: dict[str, Any]) -> str:
    """Format final browser state as the agent answer HUD graders evaluate."""
    lines = [
        f"URL: {outcome.get('url', '')}",
        f"Title: {outcome.get('title', '')}",
        f"Workflow: {outcome.get('workflowName', '')}",
        f"Steps executed: {outcome.get('steps', 0)}",
    ]
    params = outcome.get("params") or {}
    if params:
        lines.append(f"Params: {json.dumps(params)}")

    actions = outcome.get("actionsExecuted") or []
    if actions:
        lines.append("Actions taken:")
        for i, action in enumerate(actions[:20], 1):
            atype = action.get("type", "?")
            detail = action.get("text") or action.get("url") or action.get("name") or action.get("value") or ""
            lines.append(f"  {i}. {atype}: {str(detail)[:120]}")

    tree = outcome.get("accessibilityTree")
    if isinstance(tree, dict):
        elements = tree.get("elements")
        if isinstance(elements, list) and elements:
            lines.append("Visible elements:")
            for el in elements[:20]:
                if isinstance(el, dict):
                    label = el.get("text") or el.get("name") or el.get("ariaLabel") or ""
                    lines.append(f"  - [{el.get('tag', '?')}] {str(label)[:80]}")
        else:
            lines.append("Page tree: " + json.dumps(tree, default=str)[:1500])
    elif tree is not None:
        lines.append("Page tree: " + json.dumps(tree, default=str)[:1500])

    return "\n".join(lines)


async def grade_execution(outcome: dict[str, Any], *, task_id: str | None = None) -> dict[str, Any]:
    """Run HUD task template grading on a completed live browser run."""
    workflow_name = outcome.get("workflowName", "")
    task_id = task_id or _task_id_for_workflow(workflow_name)
    if task_id not in env.tasks:
        return {"reward": 0.0, "status": "no_task", "error": f"Unknown HUD task {task_id}"}

    params = _resolve_flight_params(outcome)
    runner = TaskRunner(env.tasks[task_id], params.model_dump())
    answer = _build_answer(outcome)

    log_event(
        log,
        "hud_grade_start",
        task_id=task_id,
        workflow=workflow_name,
        url=(outcome.get("url") or "")[:80],
        answer_len=len(answer),
    )

    try:
        prompt_frame = await runner.start()
        grade_frame = await runner.grade({"answer": answer})
    except Exception as exc:
        log_event(log, "hud_grade_failed", task_id=task_id, error=str(exc))
        return {"reward": 0.0, "status": "error", "error": str(exc)}

    reward = float(grade_frame.get("score", 0.0))
    result = {
        "reward": reward,
        "status": "graded",
        "taskId": task_id,
        "prompt": str(prompt_frame.get("prompt", ""))[:300],
        "subscores": grade_frame.get("subscores"),
        "content": grade_frame.get("content"),
        "info": grade_frame.get("info"),
    }
    log_event(log, "hud_grade_done", task_id=task_id, reward=reward)
    return result
