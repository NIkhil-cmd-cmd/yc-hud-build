"""Planning Mode orchestrator — decompose tasks into subtasks."""

from __future__ import annotations

import json
import os
import time
import uuid
from typing import Any

from task_index import match_task

FLIGHT_SUBTASK_TYPES = frozenset(
    {"navigate", "search_flights", "sort_by_price", "select_cheapest", "extract_result"}
)
MAX_SUBTASKS = 5

_plans: dict[str, dict[str, Any]] = {}


async def create_plan(prompt: str) -> dict[str, Any]:
    """LLM planner → structured subtask list."""
    subtasks = await _plan_with_llm(prompt)
    if not subtasks:
        subtasks = _heuristic_flight_plan(prompt)
    plan_id = f"plan_{uuid.uuid4().hex[:12]}"
    plan = {
        "planId": plan_id,
        "prompt": prompt,
        "subtasks": subtasks,
        "status": "ready",
        "currentIndex": 0,
        "createdAt": time.time(),
    }
    _plans[plan_id] = plan
    return plan


async def _plan_with_llm(prompt: str) -> list[dict[str, Any]]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return _heuristic_flight_plan(prompt)

    schema = {
        "type": "object",
        "properties": {
            "subtasks": {
                "type": "array",
                "maxItems": MAX_SUBTASKS,
                "items": {
                    "type": "object",
                    "properties": {
                        "type": {"type": "string"},
                        "description": {"type": "string"},
                        "params": {"type": "object"},
                    },
                    "required": ["type", "description"],
                },
            }
        },
        "required": ["subtasks"],
    }

    try:
        from openai import AsyncOpenAI

        client = AsyncOpenAI(api_key=api_key)
        resp = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Decompose browser automation tasks into 3-5 subtasks. "
                        f"Allowed types: {', '.join(sorted(FLIGHT_SUBTASK_TYPES))}. "
                        "Each subtask is 3-12 actions on one site. Return JSON only."
                    ),
                },
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_schema", "json_schema": {"name": "plan", "schema": schema}},
        )
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)
        subtasks = data.get("subtasks", [])
        return _validate_subtasks(subtasks)
    except Exception:
        return _heuristic_flight_plan(prompt)


def _heuristic_flight_plan(prompt: str) -> list[dict[str, Any]]:
    """Fallback flight plan when LLM unavailable."""
    lower = prompt.lower()
    params: dict[str, str] = {}
    if "boston" in lower or "bos" in lower:
        params["origin"] = "BOS"
    if "san francisco" in lower or "sfo" in lower:
        params["destination"] = "SFO"
    if "new york" in lower or "nyc" in lower:
        params["origin"] = "NYC"
    if "los angeles" in lower or "la" in lower:
        params["destination"] = "LAX"

    return _validate_subtasks(
        [
            {"type": "navigate", "description": "Open Google Flights", "params": {}},
            {
                "type": "search_flights",
                "description": "Search flights with origin, destination, date",
                "params": params,
            },
            {"type": "sort_by_price", "description": "Sort results by lowest price", "params": {}},
            {"type": "select_cheapest", "description": "Select the cheapest flight", "params": {}},
            {"type": "extract_result", "description": "Read price and airline", "params": {}},
        ]
    )


def _validate_subtasks(subtasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for i, st in enumerate(subtasks[:MAX_SUBTASKS]):
        stype = st.get("type", "extract_result")
        if stype not in FLIGHT_SUBTASK_TYPES:
            stype = "extract_result"
        out.append(
            {
                "index": i,
                "type": stype,
                "description": st.get("description", stype),
                "params": st.get("params") or {},
                "status": "pending",
            }
        )
    return out


def get_plan(plan_id: str) -> dict[str, Any] | None:
    return _plans.get(plan_id)


async def resolve_subtask_execution(subtask: dict[str, Any]) -> dict[str, Any]:
    """Decide MDP vs agent for a subtask."""
    stype = subtask.get("type", "")
    desc = subtask.get("description", stype)
    if stype == "extract_result":
        return {"mode": "agent", "goal": desc, "params": subtask.get("params", {})}

    match = await match_task(desc)
    if match.get("meetsThreshold") and match.get("bestSkill"):
        return {
            "mode": "mdp",
            "skillId": match["bestSkill"]["skillId"],
            "mdpId": match["bestSkill"]["mdpId"],
            "confidence": match["confidence"],
            "requiresConfirm": True,
        }
    return {"mode": "agent", "goal": desc, "params": subtask.get("params", {})}


def mark_subtask_done(plan_id: str, index: int, *, success: bool = True) -> dict[str, Any] | None:
    plan = _plans.get(plan_id)
    if not plan:
        return None
    subtasks = plan.get("subtasks", [])
    if 0 <= index < len(subtasks):
        subtasks[index]["status"] = "done" if success else "failed"
    plan["currentIndex"] = index + 1
    if plan["currentIndex"] >= len(subtasks):
        plan["status"] = "done"
    else:
        plan["status"] = "running"
    return plan
