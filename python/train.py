"""Graph builder + value iteration → workflow policy."""

from __future__ import annotations

import time
from typing import Any

import networkx as nx

from embeddings import cosine

THETA_STATE = 0.88


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
    return {
        "id": wid,
        "name": name,
        "policy": policy,
        "nodes": {str(n): dict(G.nodes[n]) for n in G.nodes()},
        "steps": len(buffer),
    }
