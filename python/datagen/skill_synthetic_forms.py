#!/usr/bin/env python3
"""Generic form-fill synthetic skill templates."""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from migrate_workflows_to_skills import migrate
from task_index import APP_SUPPORT, save_mdp, save_skill, skill_from_workflow, workflow_as_mdp
from train import compile_workflow_from_buffer

FORM_TEMPLATES = [
    ("Fill contact form", [
        {"url": "https://example.com/form", "action": {"type": "type", "value": "user@example.com", "ref": "email"}},
        {"url": "https://example.com/form", "action": {"type": "type", "value": "Jane Doe", "ref": "name"}},
        {"url": "https://example.com/form", "action": {"type": "click", "text": "Submit", "ref": "submit"}},
    ]),
    ("Search docs", [
        {"url": "https://example.com", "action": {"type": "click", "text": "Search", "ref": "search"}},
        {"url": "https://example.com", "action": {"type": "type", "value": "getting started", "ref": "q"}},
        {"url": "https://example.com", "action": {"type": "submit", "ref": "search-form"}},
    ]),
]


async def harvest_forms() -> dict:
    created = 0
    for name, steps in FORM_TEMPLATES:
        buffer = [{"url": s["url"], "title": name, "state_emb": [], "action": s["action"]} for s in steps]
        workflow = compile_workflow_from_buffer(name, buffer)
        wf_path = APP_SUPPORT / "workflows" / f"{workflow['id']}.json"
        wf_path.parent.mkdir(parents=True, exist_ok=True)
        wf_path.write_text(json.dumps(workflow, indent=2))
        save_skill(skill_from_workflow(workflow))
        save_mdp(workflow_as_mdp(workflow))
        created += 1
    await migrate(force=False)
    return {"created": created}


def main() -> None:
    result = asyncio.run(harvest_forms())
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
