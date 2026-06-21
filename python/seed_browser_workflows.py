#!/usr/bin/env python3
"""Install curated browser workflows + skills into OpenHive."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from task_index import (  # noqa: E402
    APP_SUPPORT,
    embed_prompt,
    rebuild_index,
    save_mdp,
    save_skill,
    workflow_as_mdp,
)
from train import compile_workflow_from_buffer  # noqa: E402
from workflow_catalog import CATALOG, WorkflowSpec, catalog_by_category  # noqa: E402

WORKFLOW_DIR = APP_SUPPORT / "workflows"
SKILLS_DIR = APP_SUPPORT / "skills"
MDPS_DIR = APP_SUPPORT / "mdps"


def _action_url(action: dict[str, Any]) -> str:
    if action.get("type") == "navigate":
        return str(action.get("url") or "")
    if action.get("type") == "search":
        return "https://www.google.com"
    return "https://www.google.com"


def _actions_to_buffer(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    buffer: list[dict[str, Any]] = []
    for action in actions:
        if action.get("type") == "wait":
            continue
        url = _action_url(action)
        buffer.append(
            {
                "url": url,
                "title": "",
                "state_emb": [],
                "action": dict(action),
            }
        )
    return buffer


def _build_skill(spec: WorkflowSpec, workflow: dict[str, Any]) -> dict[str, Any]:
    prompts = list(dict.fromkeys(spec.prompts + [spec.name, spec.name.lower(), f"run {spec.name.lower()}"]))
    return {
        "id": spec.id,
        "name": spec.name,
        "promptExamples": prompts,
        "centroid": [],
        "mdpId": spec.id,
        "bucketId": spec.category,
        "stats": {"runs": 0, "successes": 0, "lastRunAt": None},
        "legacyWorkflow": True,
        "seeded": True,
        "category": spec.category,
        "tags": spec.tags,
        "params": spec.params or None,
        "steps": workflow.get("steps", len(spec.actions)),
    }


async def install_spec(spec: WorkflowSpec, *, replace: bool = True) -> dict[str, Any]:
    wf_path = WORKFLOW_DIR / f"{spec.id}.json"
    if wf_path.exists() and not replace:
        return {"id": spec.id, "status": "skipped", "reason": "exists"}

    buffer = _actions_to_buffer(spec.actions)
    workflow = compile_workflow_from_buffer(spec.name, buffer)
    workflow["id"] = spec.id
    workflow["name"] = spec.name
    workflow["seeded"] = True
    workflow["category"] = spec.category
    workflow["tags"] = spec.tags
    if spec.params:
        workflow["params"] = spec.params

    WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
    wf_path.write_text(json.dumps(workflow, indent=2))

    skill = _build_skill(spec, workflow)
    skill["centroid"] = await embed_prompt(skill["promptExamples"][0])
    save_skill(skill)
    save_mdp(workflow_as_mdp(workflow))

    return {"id": spec.id, "name": spec.name, "category": spec.category, "status": "installed", "steps": len(spec.actions)}


async def install_catalog(
    *,
    replace: bool = True,
    categories: set[str] | None = None,
    ids: set[str] | None = None,
) -> dict[str, Any]:
    specs = CATALOG
    if categories:
        specs = [s for s in specs if s.category in categories]
    if ids:
        specs = [s for s in specs if s.id in ids]

    results: list[dict[str, Any]] = []
    for spec in specs:
        results.append(await install_spec(spec, replace=replace))

    index = await rebuild_index()
    installed = [r for r in results if r.get("status") == "installed"]
    skipped = [r for r in results if r.get("status") == "skipped"]

    return {
        "total": len(results),
        "installed": len(installed),
        "skipped": len(skipped),
        "skillsInIndex": len(index.get("skills", [])),
        "byCategory": {
            cat: len(items)
            for cat, items in catalog_by_category().items()
            if not categories or cat in categories
        },
        "workflows": installed,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed OpenHive with curated browser workflows")
    parser.add_argument("--list", action="store_true", help="List catalog without installing")
    parser.add_argument("--category", action="append", help="Only install this category (repeatable)")
    parser.add_argument("--id", action="append", help="Only install this workflow id (repeatable)")
    parser.add_argument("--no-replace", action="store_true", help="Skip workflows that already exist")
    args = parser.parse_args()

    if args.list:
        by_cat = catalog_by_category()
        print(f"Catalog: {len(CATALOG)} workflows across {len(by_cat)} categories\n")
        for cat, items in sorted(by_cat.items()):
            print(f"## {cat} ({len(items)})")
            for spec in items:
                print(f"  - {spec.id}: {spec.name}")
            print()
        return

    categories = set(args.category) if args.category else None
    ids = set(args.id) if args.id else None
    result = asyncio.run(
        install_catalog(replace=not args.no_replace, categories=categories, ids=ids)
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
