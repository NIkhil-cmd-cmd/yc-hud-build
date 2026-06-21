"""Merge new harvest traces into existing MDP and bump version."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from task_index import load_mdp, load_skill, save_mdp, save_skill
from train import build_graph, build_policy_nodes, value_iteration

from executor import dedupe_actions, normalize_actions_for_replay


async def reinforce_skill(
    skill_id: str,
    harvest_steps: list[dict[str, Any]],
    *,
    success: bool = True,
) -> dict[str, Any]:
    """Merge harvest into skill MDP and recompile policy."""
    skill = load_skill(skill_id)
    if not skill:
        raise ValueError(f"Skill not found: {skill_id}")

    mdp_id = skill.get("mdpId", skill_id)
    mdp = load_mdp(mdp_id) or {
        "id": mdp_id,
        "name": skill.get("name", skill_id),
        "policy": {},
        "policyNodes": [],
        "nodes": {},
        "actions": [],
        "version": 0,
        "reinforcementCount": 0,
    }

    harvests = [{"harvest": harvest_steps, "success": success}]
    if mdp.get("actions"):
        # Rebuild from combined: existing linear actions + new harvest
        existing_buffer = _actions_to_buffer(mdp.get("actions", []))
        combined = existing_buffer + harvest_steps
        harvests = [{"harvest": combined, "success": success}]

    G = build_graph(harvests)
    policy = value_iteration(G)
    nodes: dict[str, Any] = {}
    for n in G.nodes():
        nodes[str(n)] = dict(G.nodes[n])

    new_actions = normalize_actions_for_replay(
        dedupe_actions(
            list(mdp.get("actions") or [])
            + [s.get("action", {}) for s in harvest_steps if s.get("action")]
        )
    )

    mdp.update(
        {
            "policy": policy,
            "policyNodes": build_policy_nodes(harvests),
            "nodes": nodes,
            "actions": new_actions,
            "steps": len(new_actions),
            "version": int(mdp.get("version", 0)) + 1,
            "reinforcementCount": int(mdp.get("reinforcementCount", 0)) + 1,
            "updatedAt": time.time(),
        }
    )
    save_mdp(mdp)

    stats = skill.get("stats") or {}
    stats["runs"] = int(stats.get("runs", 0)) + 1
    if success:
        stats["successes"] = int(stats.get("successes", 0)) + 1
    stats["lastRunAt"] = time.time()
    skill["stats"] = stats
    save_skill(skill)

    return {"skillId": skill_id, "mdpId": mdp_id, "version": mdp["version"]}


def _actions_to_buffer(actions: list[dict]) -> list[dict]:
    return [{"action": a, "url": a.get("url", "")} for a in actions if a.get("type")]
