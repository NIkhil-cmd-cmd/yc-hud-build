"""Graph builder + value iteration → workflow policy."""

from __future__ import annotations

import json
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

import networkx as nx

from embeddings import cosine
from executor import dedupe_actions

THETA_STATE = 0.88


def build_policy_nodes(harvests: list[dict]) -> list[dict]:
    """Cluster states into policy nodes with action support/successRate."""
    centroids: list[dict] = []
    node_actions: dict[int, list[dict]] = defaultdict(list)

    for harvest in harvests:
        steps = harvest.get("harvest", harvest.get("steps", []))
        success = harvest.get("success", True)
        for step in steps:
            emb = step.get("state_emb") or step.get("stateEmbedding") or []
            url = step.get("url", "")
            action = step.get("action", {})
            el = step.get("selectedElement") or {}
            el_emb = step.get("elementEmbedding")
            nid = _match_or_create_policy_node(centroids, emb, url)
            node_actions[nid].append(
                {
                    "type": action.get("type"),
                    "ref": action.get("ref", action.get("selector", "")),
                    "value": action.get("value", action.get("text", "")),
                    "elementCentroid": el_emb if isinstance(el_emb, list) else [],
                    "success": 1.0 if success else 0.0,
                }
            )

    nodes: list[dict] = []
    for i, meta in enumerate(centroids):
        actions_raw = node_actions.get(i, [])
        aggregated = _aggregate_actions(actions_raw)
        nodes.append(
            {
                "id": i,
                "urlPattern": meta["url_pattern"],
                "centroid": meta["emb"],
                "members": meta["members"],
                "actions": aggregated,
            }
        )
    return nodes


def _aggregate_actions(actions: list[dict]) -> list[dict]:
    buckets: dict[tuple, list[dict]] = defaultdict(list)
    for a in actions:
        key = (a.get("type"), a.get("ref"), a.get("value"))
        buckets[key].append(a)
    out = []
    for key, group in buckets.items():
        support = len(group)
        success_rate = sum(g.get("success", 1.0) for g in group) / max(support, 1)
        sample = group[0]
        el_centroids = [g["elementCentroid"] for g in group if g.get("elementCentroid")]
        element_centroid = _mean_vec(el_centroids) if el_centroids else []
        out.append(
            {
                "type": key[0],
                "ref": key[1],
                "value": key[2],
                "elementCentroid": element_centroid,
                "successRate": round(success_rate, 3),
                "support": support,
            }
        )
    out.sort(key=lambda x: (-x["successRate"], -x["support"]))
    return out


def _mean_vec(vectors: list[list[float]]) -> list[float]:
    if not vectors:
        return []
    dim = len(vectors[0])
    return [sum(v[i] for v in vectors) / len(vectors) for i in range(dim)]


def _match_or_create_policy_node(centroids: list[dict], emb: list[float], url: str) -> int:
    pattern = _url_pattern(url)
    for i, meta in enumerate(centroids):
        if meta["url_pattern"] == pattern and cosine(emb, meta["emb"]) >= THETA_STATE:
            meta["members"] += 1
            return i
    centroids.append({"emb": emb, "url_pattern": pattern, "members": 1})
    return len(centroids) - 1


def build_policy_json(harvests: list[dict]) -> dict[str, Any]:
    nodes = build_policy_nodes(harvests)
    return {"theta": THETA_STATE, "nodes": nodes, "generatedAt": time.time()}


def write_policy_artifact(path: Path, policy: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(policy, indent=2))


def build_graph(harvests: list[dict]) -> nx.DiGraph:
    """Cluster states and aggregate edges from harvest trajectories."""
    G = nx.DiGraph()
    node_id = 0
    centroids: list[tuple[int, list[float], str]] = []

    for harvest in harvests:
        steps = harvest.get("harvest", harvest.get("steps", []))
        prev_nid: int | None = None
        for step in steps:
            emb = step.get("state_emb", [])
            url = step.get("url", "")
            nid = _match_or_create_node(centroids, emb, url)
            if nid not in G:
                G.add_node(nid, emb=emb, url=url, url_pattern=_url_pattern(url))
            action = step.get("action", {})
            if prev_nid is not None:
                G.add_edge(prev_nid, nid, action=action, success=1)
            prev_nid = nid
            node_id = max(node_id, nid + 1)

    return G


def _match_or_create_node(
    centroids: list[tuple[int, list[float], str]],
    emb: list[float],
    url: str,
) -> int:
    pattern = _url_pattern(url)
    for nid, centroid, pat in centroids:
        if pat == pattern and cosine(emb, centroid) >= THETA_STATE:
            return nid
    new_id = len(centroids)
    centroids.append((new_id, emb, pattern))
    return new_id


def _url_pattern(url: str) -> str:
    from urllib.parse import urlparse

    p = urlparse(url)
    return f"{p.netloc}{p.path.rstrip('/')}"


def value_iteration(G: nx.DiGraph, gamma: float = 0.95, max_iter: int = 20) -> dict:
    """Extract policy from graph via value iteration."""
    if not G.nodes:
        return {}

    nodes = list(G.nodes())
    V = {n: 0.0 for n in nodes}
    for _ in range(max_iter):
        delta = 0.0
        for n in nodes:
            v = V[n]
            best = 0.0
            for _, succ, data in G.out_edges(n, data=True):
                r = 1.0 if data.get("success") else 0.0
                best = max(best, r + gamma * V[succ])
            V[n] = best
            delta = max(delta, abs(v - V[n]))
        if delta < 1e-4:
            break

    policy: dict[int, dict] = {}
    for n in nodes:
        best_succ = None
        best_q = -1.0
        best_action = {}
        for _, succ, data in G.out_edges(n, data=True):
            r = 1.0 if data.get("success") else 0.0
            q = r + gamma * V[succ]
            if q > best_q:
                best_q = q
                best_succ = succ
                best_action = data.get("action", {})
        if best_succ is not None:
            policy[n] = {"next": best_succ, "action": best_action}

    return {str(k): v for k, v in policy.items()}


def compile_workflow_from_buffer(name: str, buffer: list[dict]) -> dict[str, Any]:
    G = build_graph([{"harvest": buffer, "success": True}])
    policy = value_iteration(G)
    wid = f"wf_{int(time.time())}"
    nodes = {}
    for n in G.nodes():
        node = dict(G.nodes[n])
        if "emb" not in node and buffer:
            node["emb"] = node.get("state_emb") or (buffer[0].get("state_emb") if buffer else [])
        nodes[str(n)] = node
    actions = dedupe_actions([
        step.get("action", {})
        for step in buffer
        if step.get("action", {}).get("type") in {"click", "type", "navigate", "fill", "submit"}
    ])
    return {
        "id": wid,
        "name": name,
        "policy": policy,
        "policyNodes": build_policy_nodes([{"harvest": buffer, "success": True}]),
        "nodes": nodes,
        "actions": actions,
        "steps": len(buffer),
    }
