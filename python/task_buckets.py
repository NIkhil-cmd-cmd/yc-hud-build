"""Auto k-means buckets for skill clustering."""

from __future__ import annotations

import json
import os
import random
from pathlib import Path
from typing import Any

from embeddings import cosine
from task_index import APP_SUPPORT, list_skills, save_skill

BUCKETS_PATH = APP_SUPPORT / "buckets.json"
DEFAULT_K = int(os.environ.get("OPENHIVE_BUCKET_K", "4"))


def _kmeans(vectors: list[list[float]], k: int, max_iter: int = 20) -> list[int]:
    """Simple k-means; returns cluster assignment per vector."""
    n = len(vectors)
    if n == 0:
        return []
    k = min(k, n)
    if k <= 1:
        return [0] * n

    rng = random.Random(42)
    centroids = [list(vectors[i]) for i in rng.sample(range(n), k)]
    assignments = [0] * n

    for _ in range(max_iter):
        changed = False
        for i, vec in enumerate(vectors):
            best_j, best_sim = 0, -1.0
            for j, c in enumerate(centroids):
                sim = cosine(vec, c)
                if sim > best_sim:
                    best_sim, best_j = sim, j
            if assignments[i] != best_j:
                assignments[i] = best_j
                changed = True
        if not changed:
            break
        for j in range(k):
            members = [vectors[i] for i, a in enumerate(assignments) if a == j]
            if members:
                dim = len(members[0])
                centroids[j] = [sum(m[d] for m in members) / len(members) for d in range(dim)]
    return assignments


async def _label_bucket(skill_names: list[str]) -> str:
    """Auto-label bucket via gpt-4o-mini one-shot."""
    if not skill_names:
        return "General"
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return _heuristic_label(skill_names)

    try:
        from openai import AsyncOpenAI

        client = AsyncOpenAI(api_key=api_key)
        resp = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": "Reply with a single short category label (1-2 words) for these browser automation skills.",
                },
                {"role": "user", "content": ", ".join(skill_names[:8])},
            ],
            max_tokens=10,
        )
        label = (resp.choices[0].message.content or "").strip().strip('"')
        return label[:32] or _heuristic_label(skill_names)
    except Exception:
        return _heuristic_label(skill_names)


def _heuristic_label(names: list[str]) -> str:
    text = " ".join(names).lower()
    if any(w in text for w in ("flight", "travel", "hotel", "book")):
        return "Travel"
    if any(w in text for w in ("shop", "cart", "buy", "amazon")):
        return "Shopping"
    if any(w in text for w in ("form", "email", "signup", "login")):
        return "Forms"
    return "General"


async def rebuild_buckets(k: int | None = None) -> dict[str, Any]:
    """Cluster skills into k-means buckets and persist."""
    skills = list_skills()
    if not skills:
        data = {"version": 1, "buckets": [], "k": 0}
        BUCKETS_PATH.write_text(json.dumps(data, indent=2))
        return data

    vectors: list[list[float]] = []
    valid_skills: list[dict[str, Any]] = []
    for s in skills:
        c = s.get("centroid") or []
        if c:
            vectors.append(c)
            valid_skills.append(s)

    if not vectors:
        data = {"version": 1, "buckets": [], "k": 0}
        BUCKETS_PATH.write_text(json.dumps(data, indent=2))
        return data

    num_k = k or min(DEFAULT_K, len(vectors))
    assignments = _kmeans(vectors, num_k)
    clusters: dict[int, list[dict[str, Any]]] = {i: [] for i in range(num_k)}
    for skill, assign in zip(valid_skills, assignments):
        clusters[assign].append(skill)

    buckets: list[dict[str, Any]] = []
    for i, members in clusters.items():
        if not members:
            continue
        names = [m.get("name", m["id"]) for m in members]
        label = await _label_bucket(names)
        bucket_id = f"bucket_{i}"
        skill_ids = [m["id"] for m in members]
        member_centroids = [m.get("centroid") or [] for m in members if m.get("centroid")]
        centroid: list[float] = []
        if member_centroids:
            dim = len(member_centroids[0])
            centroid = [
                sum(c[d] for c in member_centroids) / len(member_centroids) for d in range(dim)
            ]
        buckets.append(
            {
                "id": bucket_id,
                "label": label,
                "centroid": centroid,
                "skillIds": skill_ids,
            }
        )
        for m in members:
            m["bucketId"] = bucket_id
            save_skill(m)

    data = {"version": 1, "k": num_k, "buckets": buckets}
    BUCKETS_PATH.write_text(json.dumps(data, indent=2))
    return data


def load_buckets() -> dict[str, Any]:
    if not BUCKETS_PATH.exists():
        return {"version": 1, "buckets": [], "k": 0}
    return json.loads(BUCKETS_PATH.read_text())


async def list_buckets_with_skills() -> dict[str, Any]:
    """Return buckets enriched with skill metadata."""
    data = load_buckets()
    skill_map = {s["id"]: s for s in list_skills()}
    enriched = []
    for b in data.get("buckets", []):
        skills = [
            {
                "id": sid,
                "name": skill_map[sid].get("name", sid),
                "stats": skill_map[sid].get("stats", {}),
            }
            for sid in b.get("skillIds", [])
            if sid in skill_map
        ]
        enriched.append({**b, "skills": skills})
    return {"buckets": enriched, "k": data.get("k", 0)}
