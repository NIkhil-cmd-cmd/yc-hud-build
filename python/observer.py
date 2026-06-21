"""Passive browser observer — captures user actions without record/stop UI."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Awaitable, Callable

from embeddings import embed_state
from log_config import log_event, setup_logging

log = setup_logging("openhive.observer")

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
        log_event(log, "observer_created", session_id=session_id)

    async def ingest(self, event: dict) -> None:
        if not self.active:
            log_event(log, "ingest_skipped_inactive", session_id=self.session_id)
            return
        action_type = event.get("type", "")
        if action_type not in MEANINGFUL:
            log_event(
                log,
                "ingest_skipped_type",
                session_id=self.session_id,
                action_type=action_type or "(empty)",
            )
            return

        url = event.get("url", "")
        title = event.get("title", "")
        tree = event.get("accessibilityTree")
        log_event(
            log,
            "ingest_embedding",
            session_id=self.session_id,
            action_type=action_type,
            url=url[:80],
        )
        emb = await embed_state(url, title, tree)
        emb_dims = len(emb) if emb else 0

        step = {
            "ts": time.time(),
            "url": url,
            "title": title,
            "state_emb": emb,
            "action": {k: v for k, v in event.items() if k not in ("accessibilityTree",)},
        }
        self.buffer.append(step)
        with self._log_path.open("a") as f:
            f.write(json.dumps({**step, "state_emb": f"[{emb_dims} dims]"}) + "\n")

        log_event(
            log,
            "ingest_stored",
            session_id=self.session_id,
            buffer_len=len(self.buffer),
            action_type=action_type,
            emb_dims=emb_dims,
        )

        result = self.on_step(step)
        if result is not None:
            await result
