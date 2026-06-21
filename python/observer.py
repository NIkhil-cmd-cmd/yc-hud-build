"""Passive browser observer — captures user actions without record/stop UI."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Awaitable, Callable

from embeddings import embed_state

OnStep = Callable[[dict], Awaitable[None] | None]

MEANINGFUL = frozenset({"click", "type", "navigate", "submit", "fill"})


class Observer:
    """Always-on observer. Filters noise; embeds state on each meaningful action."""

    def __init__(self, session_id: str, on_step: OnStep):
        self.session_id = session_id
        self.on_step = on_step
        self.buffer: list[dict] = []
        self.active = True
        self._log_path = (
            Path.home()
            / "Library/Application Support/OpenHive/harvest"
            / f"session_{session_id}.jsonl"
        )
        self._log_path.parent.mkdir(parents=True, exist_ok=True)

    async def ingest(self, event: dict) -> None:
        if not self.active:
            return
        action_type = event.get("type", "")
        if action_type not in MEANINGFUL:
            return

        url = event.get("url", "")
        title = event.get("title", "")
        tree = event.get("accessibilityTree")
        emb = await embed_state(url, title, tree)

        step = {
            "ts": time.time(),
            "url": url,
            "title": title,
            "state_emb": emb,
            "action": {k: v for k, v in event.items() if k not in ("accessibilityTree",)},
        }
        self.buffer.append(step)
        with self._log_path.open("a") as f:
            import json

            f.write(json.dumps(step) + "\n")

        result = self.on_step(step)
        if result is not None:
            await result
