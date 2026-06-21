"""Skill index — KNN routing over prompt embeddings."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from embeddings import cosine, embed_state

APP_SUPPORT = Path.home() / "Library/Application Support/OpenHive"
SKILLS_DIR = APP_SUPPORT / "skills"
MDPS_DIR = APP_SUPPORT / "mdps"
INDEX_DIR = APP_SUPPORT / "index"
INDEX_PATH = INDEX_DIR / "skills.json"
TRACES_DIR = APP_SUPPORT / "traces"
BENCHMARKS_DIR = APP_SUPPORT / "benchmarks"

for d in (SKILLS_DIR, MDPS_DIR, INDEX_DIR, TRACES_DIR, BENCHMARKS_DIR):
    d.mkdir(parents=True, exist_ok=True)

MATCH_THRESHOLD = float(os.environ.get("OPENHIVE_TASK_MATCH_THRESHOLD", "0.82"))
TOP_K = int(os.environ.get("OPENHIVE_TASK_MATCH_TOP_K", "5"))


async def embed_prompt(text: str) -> list[float]:
    """Embed a user prompt for skill matching."""
    return await embed_state("", text.strip(), None)


def load_index() -> dict[str, Any]:
    if not INDEX_PATH.exists():
        return {"version": 1, "skills": []}
    return json.loads(INDEX_PATH.read_text())


def save_index(data: dict[str, Any]) -> None:
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(json.dumps(data, indent=2))


def load_skill(skill_id: str) -> dict[str, Any] | None:
    path = SKILLS_DIR / f"{skill_id}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


def save_skill(skill: dict[str, Any]) -> None:
    SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    sid = skill["id"]
    (SKILLS_DIR / f"{sid}.json").write_text(json.dumps(skill, indent=2))


def load_mdp(mdp_id: str) -> dict[str, Any] | None:
    path = MDPS_DIR / f"{mdp_id}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


def save_mdp(mdp: dict[str, Any]) -> None:
    MDPS_DIR.mkdir(parents=True, exist_ok=True)
    mid = mdp["id"]
    (MDPS_DIR / f"{mid}.json").write_text(json.dumps(mdp, indent=2))


def list_skills() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for p in sorted(SKILLS_DIR.glob("*.json")):
        try:
            out.append(json.loads(p.read_text()))
        except json.JSONDecodeError:
            continue
    return out


async def rebuild_index() -> dict[str, Any]:
    """Rebuild KNN index from skill files."""
    entries: list[dict[str, Any]] = []
    for skill in list_skills():
        centroid = skill.get("centroid") or []
        if not centroid:
            examples = skill.get("promptExamples") or [skill.get("name", "")]
            text = examples[0] if examples else skill.get("name", "")
            centroid = await embed_prompt(str(text))
            skill["centroid"] = centroid
            save_skill(skill)
        entries.append(
            {
                "id": skill["id"],
                "name": skill.get("name", skill["id"]),
                "mdpId": skill.get("mdpId", skill["id"]),
                "bucketId": skill.get("bucketId"),
                "centroid": centroid,
                "stats": skill.get("stats", {}),
            }
        )
    data = {"version": 1, "skills": entries, "updatedAt": __import__("time").time()}
    save_index(data)
    return data


async def match_task(prompt: str, *, top_k: int | None = None) -> dict[str, Any]:
    """Top-k KNN skill matches for a user prompt."""
    k = top_k or TOP_K
    index = load_index()
    if not index.get("skills"):
        await rebuild_index()
        index = load_index()
    query = await embed_prompt(prompt)
    scored: list[tuple[float, dict[str, Any]]] = []
    for entry in index.get("skills", []):
        centroid = entry.get("centroid") or []
        if not centroid:
            continue
        sim = cosine(query, centroid)
        scored.append((sim, entry))
    scored.sort(key=lambda x: -x[0])
    matches = [
        {
            "skillId": e["id"],
            "name": e.get("name", e["id"]),
            "mdpId": e.get("mdpId", e["id"]),
            "bucketId": e.get("bucketId"),
            "confidence": round(sim, 4),
        }
        for sim, e in scored[:k]
    ]
    best = matches[0] if matches else None
    best_conf = best["confidence"] if best else 0.0
    return {
        "prompt": prompt,
        "matches": matches,
        "bestSkill": best,
        "confidence": best_conf,
        "meetsThreshold": best_conf >= MATCH_THRESHOLD,
        "threshold": MATCH_THRESHOLD,
    }


def workflow_as_mdp(workflow: dict[str, Any]) -> dict[str, Any]:
    """Convert legacy workflow dict to MDP storage format."""
    wid = workflow.get("id", "unknown")
    return {
        "id": wid,
        "name": workflow.get("name", wid),
        "policy": workflow.get("policy", {}),
        "policyNodes": workflow.get("policyNodes", []),
        "nodes": workflow.get("nodes", {}),
        "actions": workflow.get("actions", []),
        "steps": workflow.get("steps", 0),
        "version": workflow.get("version", 1),
        "reinforcementCount": workflow.get("reinforcementCount", 0),
    }


def skill_from_workflow(workflow: dict[str, Any]) -> dict[str, Any]:
    wid = workflow.get("id", f"wf_{int(__import__('time').time())}")
    name = workflow.get("name", "Untitled")
    return {
        "id": wid,
        "name": name,
        "promptExamples": [name, f"run {name.lower()}", f"execute {name.lower()}"],
        "centroid": [],
        "mdpId": wid,
        "bucketId": None,
        "stats": {
            "runs": 0,
            "successes": 0,
            "lastRunAt": None,
        },
        "legacyWorkflow": True,
    }
