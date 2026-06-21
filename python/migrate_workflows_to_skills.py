#!/usr/bin/env python3
"""One-time migration: workflows/*.json → skills/ + mdps/."""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from task_buckets import rebuild_buckets
from task_index import (
    APP_SUPPORT,
    MDPS_DIR,
    SKILLS_DIR,
    embed_prompt,
    rebuild_index,
    save_mdp,
    save_skill,
    skill_from_workflow,
    workflow_as_mdp,
)

WORKFLOW_DIR = APP_SUPPORT / "workflows"


async def migrate(*, force: bool = False) -> dict:
    WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
    SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    MDPS_DIR.mkdir(parents=True, exist_ok=True)

    migrated = 0
    skipped = 0
    for path in sorted(WORKFLOW_DIR.glob("*.json")):
        if path.name.endswith("_policy.json"):
            continue
        try:
            workflow = json.loads(path.read_text())
        except json.JSONDecodeError:
            skipped += 1
            continue
        wid = workflow.get("id", path.stem)
        skill_path = SKILLS_DIR / f"{wid}.json"
        mdp_path = MDPS_DIR / f"{wid}.json"
        if skill_path.exists() and mdp_path.exists() and not force:
            skipped += 1
            continue

        skill = skill_from_workflow(workflow)
        name = skill["name"]
        skill["centroid"] = await embed_prompt(name)
        save_skill(skill)

        mdp = workflow_as_mdp(workflow)
        save_mdp(mdp)
        migrated += 1

    await rebuild_index()
    await rebuild_buckets()
    return {"migrated": migrated, "skipped": skipped}


def main() -> None:
    force = "--force" in sys.argv
    result = asyncio.run(migrate(force=force))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
