"""State and element embeddings via OpenAI text-embedding-3-small."""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any

_cache: dict[str, list[float]] = {}


def _cache_key(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


async def embed_state(url: str, title: str, tree: Any | None) -> list[float]:
    """Embed page state from URL, title, and accessibility tree snapshot."""
    tree_text = ""
    if tree is not None:
        tree_text = json.dumps(tree, default=str)[:8000]
    text = f"url:{url}\ntitle:{title}\ntree:{tree_text}"
    return await _embed(text)


async def embed_element(label: str, role: str = "", ref: str = "") -> list[float]:
    text = f"ref:{ref} role:{role} label:{label}"
    return await _embed(text)


async def _embed(text: str) -> list[float]:
    key = _cache_key(text)
    if key in _cache:
        return _cache[key]

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        # Deterministic stub for dev without API key
        h = int(hashlib.sha256(text.encode()).hexdigest()[:8], 16)
        stub = [(h >> (i % 24)) & 0xFF for i in range(1536)]
        _cache[key] = stub
        return stub

    from openai import AsyncOpenAI

    client = AsyncOpenAI(api_key=api_key)
    resp = await client.embeddings.create(
        model="text-embedding-3-small",
        input=text[:8000],
    )
    vec = resp.data[0].embedding
    _cache[key] = vec
    return vec


def cosine(a: list[float], b: list[float]) -> float:
    import math

    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)
