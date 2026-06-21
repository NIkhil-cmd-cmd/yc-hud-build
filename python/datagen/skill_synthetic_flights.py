#!/usr/bin/env python3
"""Offline synthetic flight trace harvest for skill MDP training."""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from migrate_workflows_to_skills import migrate
from task_index import APP_SUPPORT, save_mdp, save_skill, skill_from_workflow
from train import compile_workflow_from_buffer


async def harvest_flights(limit: int = 3) -> dict:
    """Compile flight workflows from smoke TASK_MATRIX subset."""
    try:
        from smoke.run_local_browser_trace_gate import TASK_MATRIX
    except ImportError:
        TASK_MATRIX = [
            {"origin": "BOS", "destination": "SFO", "departDate": "2026-07-15"},
            {"origin": "NYC", "destination": "LAX", "departDate": "2026-08-01"},
            {"origin": "ORD", "destination": "MIA", "departDate": "2026-09-10"},
        ]

    created = 0
    for task in TASK_MATRIX[:limit]:
        name = f"Book flight {task['origin']} to {task['destination']}"
        # Stub harvest — real offline harvest uses Playwright gate script
        buffer = [
            {
                "url": "https://www.google.com/travel/flights",
                "title": "Google Flights",
                "state_emb": [],
                "action": {"type": "navigate", "url": "https://www.google.com/travel/flights"},
            },
            {
                "url": "https://www.google.com/travel/flights",
                "title": "Google Flights",
                "state_emb": [],
                "action": {"type": "click", "text": "Origin", "ref": "origin"},
            },
            {
                "url": "https://www.google.com/travel/flights",
                "title": "Google Flights",
                "state_emb": [],
                "action": {"type": "type", "value": task["origin"], "ref": "origin"},
            },
        ]
        workflow = compile_workflow_from_buffer(name, buffer)
        workflow["flightParams"] = task
        wf_path = APP_SUPPORT / "workflows" / f"{workflow['id']}.json"
        wf_path.parent.mkdir(parents=True, exist_ok=True)
        wf_path.write_text(json.dumps(workflow, indent=2))
        skill = skill_from_workflow(workflow)
        save_skill(skill)
        from task_index import workflow_as_mdp

        save_mdp(workflow_as_mdp(workflow))
        created += 1

    await migrate(force=False)
    return {"created": created, "limit": limit}


def main() -> None:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    result = asyncio.run(harvest_flights(limit))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
