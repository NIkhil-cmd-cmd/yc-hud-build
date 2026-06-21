"""Hardcoded Google Flights demo — learn once (slow), replay via scripted MDP (fast)."""

from __future__ import annotations

import json
from typing import Any

from task_index import (
    APP_SUPPORT,
    rebuild_index,
    save_mdp,
    save_skill,
    skill_from_workflow,
    workflow_as_mdp,
)
from train import compile_workflow_from_buffer

DEMO_SKILL_ID = "demo_flight_bos_sfo"
DEMO_NAME = "Book flight BOS to SFO"
FLIGHTS_URL = "https://www.google.com/travel/flights"

DEMO_TASK: dict[str, str] = {
    "origin": "BOS",
    "destination": "SFO",
    "departDate": "2026-07-15",
}

DEMO_PROMPTS = [
    "book a flight from boston to san francisco",
    "book flight bos to sfo",
    "flight from boston to sf july 15",
    "search flights boston san francisco",
    DEMO_NAME.lower(),
]


def is_flight_prompt(prompt: str) -> bool:
    p = (prompt or "").lower()
    return "flight" in p or ("bos" in p and "sfo" in p) or ("boston" in p and "san francisco" in p)


def skill_exists() -> bool:
    return (APP_SUPPORT / "skills" / f"{DEMO_SKILL_ID}.json").exists()


def scripted_swift_actions(task: dict[str, str] | None = None) -> list[dict[str, Any]]:
    """Label-based actions that work in Nook WKWebView (no LLM / no refs)."""
    t = task or DEMO_TASK
    origin, dest = t["origin"], t["destination"]
    depart = t["departDate"]
    return [
        {"type": "click", "text": "Round trip", "partial": True},
        {"type": "click", "text": "One way", "partial": True},
        {"type": "click", "text": "Where from", "partial": True},
        {"type": "press", "value": "Meta+a"},
        {"type": "type", "value": origin, "text": "Where from"},
        {"type": "click", "text": "Boston", "partial": True},
        {"type": "click", "text": "Where to", "partial": True},
        {"type": "press", "value": "Meta+a"},
        {"type": "type", "value": dest, "text": "Where to"},
        {"type": "click", "text": "San Francisco", "partial": True},
        {"type": "click", "text": "Departure", "partial": True},
        {"type": "type", "value": depart, "text": "Departure"},
        {"type": "click", "text": "Done", "partial": True},
        {"type": "click", "text": "Search", "partial": True},
    ]


def _hardcoded_buffer() -> list[dict[str, Any]]:
    """Workflow buffer for MDP graph visualization."""
    return [
        {"url": FLIGHTS_URL, "state_emb": [], "action": action}
        for action in scripted_swift_actions()
        if action.get("type") != "press"
    ]


async def save_demo_workflow(workflow: dict[str, Any]) -> str:
    """Persist workflow + skill + MDP under fixed demo id."""
    workflow["id"] = DEMO_SKILL_ID
    workflow["name"] = DEMO_NAME
    workflow["flightParams"] = dict(DEMO_TASK)
    workflow["demoFlight"] = True

    wf_dir = APP_SUPPORT / "workflows"
    wf_dir.mkdir(parents=True, exist_ok=True)
    (wf_dir / f"{DEMO_SKILL_ID}.json").write_text(json.dumps(workflow, indent=2))

    skill = skill_from_workflow(workflow)
    skill["id"] = DEMO_SKILL_ID
    skill["name"] = DEMO_NAME
    skill["promptExamples"] = list(DEMO_PROMPTS)
    skill["mdpId"] = DEMO_SKILL_ID
    skill["demoFlight"] = True
    from task_index import embed_prompt

    skill["centroid"] = await embed_prompt(DEMO_PROMPTS[0])
    save_skill(skill)
    save_mdp(workflow_as_mdp(workflow))
    await rebuild_index()
    return DEMO_SKILL_ID


async def install_hardcoded_skill() -> str:
    workflow = compile_workflow_from_buffer(DEMO_NAME, _hardcoded_buffer())
    return await save_demo_workflow(workflow)


def match_replay_result(prompt: str) -> dict[str, Any]:
    """Force skill match for flight demo replay."""
    return {
        "prompt": prompt,
        "matches": [
            {
                "skillId": DEMO_SKILL_ID,
                "name": DEMO_NAME,
                "mdpId": DEMO_SKILL_ID,
                "bucketId": None,
                "confidence": 0.99,
            }
        ],
        "bestSkill": {
            "skillId": DEMO_SKILL_ID,
            "name": DEMO_NAME,
            "mdpId": DEMO_SKILL_ID,
            "bucketId": None,
            "confidence": 0.99,
        },
        "confidence": 0.99,
        "meetsThreshold": True,
        "threshold": 0.82,
        "flightDemoReplay": True,
    }


def match_learn_result(prompt: str) -> dict[str, Any]:
    """First-run flight demo — no skill yet, route to learning."""
    return {
        "prompt": prompt,
        "matches": [],
        "bestSkill": None,
        "confidence": 0.0,
        "meetsThreshold": False,
        "threshold": 0.82,
        "flightDemoLearn": True,
        "flightDemoTask": DEMO_TASK,
    }
