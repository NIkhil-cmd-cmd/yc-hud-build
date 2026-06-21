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
    skills = APP_SUPPORT / "skills"
    if (skills / f"{DEMO_SKILL_ID}.json").exists():
        return True
    return any(skills.glob("flight_*.json"))


def scripted_swift_actions(task: dict[str, str] | None = None) -> list[dict[str, Any]]:
    """Label-based actions for Nook WKWebView — navigate first, keyboard for airports."""
    t = task or DEMO_TASK
    origin, dest = t["origin"], t["destination"]
    day = str(int(t["departDate"].split("-")[2]))
    return [
        {"type": "navigate", "url": FLIGHTS_URL},
        {"type": "wait", "text": "Where from", "timeout": 25_000},
        {"type": "click", "text": "One way", "partial": True},
        {"type": "click", "text": "Where from", "partial": True},
        {"type": "type", "value": origin, "text": "Where from"},
        {"type": "wait", "value": "1500"},
        {"type": "press", "value": "ArrowDown"},
        {"type": "press", "value": "Enter"},
        {"type": "click", "text": "Where to", "partial": True},
        {"type": "type", "value": dest, "text": "Where to"},
        {"type": "wait", "value": "1500"},
        {"type": "press", "value": "ArrowDown"},
        {"type": "press", "value": "Enter"},
        {"type": "click", "text": "Departure", "partial": True},
        {"type": "wait", "value": "1000"},
        {"type": "click", "text": day, "partial": True},
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
    workflow = _inject_demo_branching(workflow)
    return await save_demo_workflow(workflow)


def _inject_demo_branching(workflow: dict[str, Any]) -> dict[str, Any]:
    """Simulate multi-pass training: current one-way path vs legacy round-trip traces."""
    workflow.setdefault("nodes", {})
    workflow["nodes"].setdefault(
        "12",
        {
            "emb": [],
            "url": FLIGHTS_URL,
            "url_pattern": "www.google.com/travel/flights",
            "label": "Round-trip flow (legacy)",
        },
    )
    workflow["nodes"].setdefault(
        "13",
        {
            "emb": [],
            "url": FLIGHTS_URL,
            "url_pattern": "www.google.com/travel/flights",
            "label": "Return date picker (deprecated)",
        },
    )

    workflow["transitions"] = [
        {
            "from": "0",
            "to": "1",
            "action": {"type": "click", "value": "One way", "text": "One way"},
            "weight": 0.85,
            "support": 17,
            "primary": True,
        },
        {
            "from": "0",
            "to": "12",
            "action": {"type": "click", "value": "Round trip", "text": "Round trip"},
            "weight": 0.15,
            "support": 3,
            "primary": False,
        },
        {
            "from": "12",
            "to": "13",
            "action": {"type": "click", "value": "Return", "text": "Return"},
            "weight": 0.12,
            "support": 3,
            "primary": False,
        },
        {
            "from": "1",
            "to": "2",
            "action": {"type": "click", "value": "Where from", "text": "Where from"},
            "weight": 0.92,
            "support": 20,
            "primary": True,
        },
        {
            "from": "2",
            "to": "3",
            "action": {"type": "type", "value": "BOS", "text": "Where from"},
            "weight": 0.78,
            "support": 14,
            "primary": True,
        },
        {
            "from": "2",
            "to": "4",
            "action": {"type": "click", "value": "Boston", "text": "Boston"},
            "weight": 0.22,
            "support": 4,
            "primary": False,
        },
        {
            "from": "3",
            "to": "4",
            "action": {"type": "click", "value": "Boston", "text": "Boston"},
            "weight": 0.88,
            "support": 16,
            "primary": True,
        },
        {
            "from": "4",
            "to": "5",
            "action": {"type": "click", "value": "Where to", "text": "Where to"},
            "weight": 0.9,
            "support": 18,
            "primary": True,
        },
        {
            "from": "5",
            "to": "6",
            "action": {"type": "type", "value": "SFO", "text": "Where to"},
            "weight": 0.8,
            "support": 15,
            "primary": True,
        },
        {
            "from": "5",
            "to": "7",
            "action": {"type": "click", "value": "San Francisco", "text": "San Francisco"},
            "weight": 0.2,
            "support": 4,
            "primary": False,
        },
        {
            "from": "6",
            "to": "7",
            "action": {"type": "click", "value": "San Francisco", "text": "San Francisco"},
            "weight": 0.86,
            "support": 14,
            "primary": True,
        },
        {
            "from": "7",
            "to": "8",
            "action": {"type": "click", "value": "Departure", "text": "Departure"},
            "weight": 0.91,
            "support": 19,
            "primary": True,
        },
        {
            "from": "8",
            "to": "9",
            "action": {"type": "type", "value": DEMO_TASK["departDate"], "text": "Departure"},
            "weight": 0.74,
            "support": 11,
            "primary": True,
        },
        {
            "from": "8",
            "to": "9",
            "action": {"type": "click", "value": "15", "text": "15"},
            "weight": 0.26,
            "support": 5,
            "primary": False,
        },
        {
            "from": "9",
            "to": "10",
            "action": {"type": "click", "value": "Done", "text": "Done"},
            "weight": 0.93,
            "support": 20,
            "primary": True,
        },
        {
            "from": "10",
            "to": "11",
            "action": {"type": "click", "value": "Search", "text": "Search"},
            "weight": 0.95,
            "support": 20,
            "primary": True,
        },
    ]

    for node in workflow.get("policyNodes") or []:
        nid = node.get("id")
        if nid == 0:
            node["members"] = 20
            node["actions"] = [
                {
                    "type": "click",
                    "ref": "",
                    "value": "One way",
                    "elementCentroid": [],
                    "successRate": 0.85,
                    "support": 17,
                },
                {
                    "type": "click",
                    "ref": "",
                    "value": "Round trip",
                    "elementCentroid": [],
                    "successRate": 0.15,
                    "support": 3,
                },
            ]
        elif nid == 2:
            node["members"] = 18
            node["actions"] = [
                {
                    "type": "type",
                    "ref": "",
                    "value": "BOS",
                    "elementCentroid": [],
                    "successRate": 0.78,
                    "support": 14,
                },
                {
                    "type": "click",
                    "ref": "",
                    "value": "Boston",
                    "elementCentroid": [],
                    "successRate": 0.22,
                    "support": 4,
                },
            ]

    workflow["reinforcementCount"] = 4
    workflow["harvestHistory"] = [
        {"version": 1, "success": True, "note": "round-trip traces"},
        {"version": 2, "success": True, "note": "mixed airport entry"},
        {"version": 3, "success": True, "note": "one-way preferred"},
        {"version": 4, "success": True, "note": "current best path"},
    ]
    return workflow


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
