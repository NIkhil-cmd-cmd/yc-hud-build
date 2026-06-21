"""Policy executor — Tier 1 policy lookup, Tier 2 Fireworks, Tier 3 MiniMax."""

from __future__ import annotations

import json
import os
import time
from typing import Any

from embeddings import cosine, embed_state
from exa_client import get_page_schema

STATE_THRESHOLD = 0.82
ELEMENT_THRESHOLD = 0.72
MAX_STEPS = 25


class PolicyExecutor:
    def __init__(self, workflow: dict[str, Any], params: dict[str, str] | None = None):
        self.workflow = workflow
        self.policy = workflow.get("policy", {})
        self.nodes = workflow.get("nodes", {})
        self.params = params or {}
        self.tokens = 0
        self.tier_log: list[int] = []
        self.step_index = 0

    async def next_action(
        self,
        url: str,
        title: str,
        accessibility_tree: Any,
    ) -> dict[str, Any]:
        """Return next action for Swift to perform on WKWebView."""
        state_emb = await embed_state(url, title, accessibility_tree)

        best_nid, best_sim = None, -1.0
        for nid, node in self.nodes.items():
            emb = node.get("emb") or node.get("state_emb")
            if emb:
                sim = cosine(state_emb, emb)
                if sim > best_sim:
                    best_sim, best_nid = sim, nid

        if best_nid and best_sim >= STATE_THRESHOLD and best_nid in self.policy:
            entry = self.policy[best_nid]
            action = self._templatize(entry.get("action", {}))
            self.tier_log.append(1)
            self.step_index += 1
            return {
                "done": False,
                "tier": 1,
                "tokens": self.tokens,
                "action": action,
                "sim": round(best_sim, 3),
            }

        # Tier 2 — Fireworks fast model
        tier2 = await self._fireworks_action(url, title, accessibility_tree)
        if tier2:
            self.tokens += tier2.get("tokens_used", 200)
            self.tier_log.append(2)
            self.step_index += 1
            return {
                "done": False,
                "tier": 2,
                "tokens": self.tokens,
                "action": tier2["action"],
            }

        # Tier 3 — MiniMax
        tier3 = await self._minimax_action(url, title, accessibility_tree)
        if tier3:
            self.tokens += tier3.get("tokens_used", 800)
            self.tier_log.append(3)
            self.step_index += 1
            return {
                "done": False,
                "tier": 3,
                "tokens": self.tokens,
                "action": tier3["action"],
            }

        return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "no_action"}

    def _templatize(self, action: dict) -> dict:
        out = dict(action)
        text = out.get("text") or out.get("value") or ""
        if isinstance(text, str):
            for k, v in self.params.items():
                text = text.replace(f"{{{k}}}", str(v))
            if "text" in out:
                out["text"] = text
            if "value" in out:
                out["value"] = text
        return out

    async def _fireworks_action(self, url: str, title: str, tree: Any) -> dict | None:
        api_key = os.environ.get("FIREWORKS_API_KEY")
        if not api_key:
            schema = await get_page_schema(url)
            return {"action": {"type": "navigate", "url": url}, "tokens_used": 0}

        from openai import AsyncOpenAI

        client = AsyncOpenAI(base_url="https://api.fireworks.ai/inference/v1", api_key=api_key)
        schema = await get_page_schema(url)
        prompt = (
            f"URL: {url}\nTitle: {title}\nSchema: {schema[:500]}\n"
            f"Tree: {json.dumps(tree, default=str)[:1500]}\n"
            'Return JSON only: {"type":"click","ref":"@e0"} or {"type":"type","ref":"@e1","value":"text"}'
        )
        try:
            r = await client.chat.completions.create(
                model="accounts/fireworks/models/llama-v3p1-8b-instruct",
                messages=[{"role": "user", "content": prompt}],
                temperature=0,
                max_tokens=80,
            )
            text = r.choices[0].message.content or "{}"
            usage = r.usage.total_tokens if r.usage else 200
            action = json.loads(text.strip().strip("`").replace("json", ""))
            return {"action": action, "tokens_used": usage}
        except Exception:
            return None

    async def _minimax_action(self, url: str, title: str, tree: Any) -> dict | None:
        api_key = os.environ.get("MINIMAX_API_KEY")
        if not api_key:
            return None

        from openai import AsyncOpenAI

        client = AsyncOpenAI(
            base_url="https://api.minimaxi.chat/v1",
            api_key=api_key,
        )
        prompt = (
            f"Browser task step. URL: {url}\nTitle: {title}\n"
            f"Elements: {json.dumps(tree, default=str)[:2000]}\n"
            'Next action JSON: {"type":"click","ref":"@e0"}'
        )
        try:
            r = await client.chat.completions.create(
                model="MiniMax-Text-01",
                messages=[{"role": "user", "content": prompt}],
                temperature=0,
                max_tokens=120,
            )
            text = r.choices[0].message.content or "{}"
            usage = r.usage.total_tokens if r.usage else 800
            action = json.loads(text.strip().strip("`").replace("json", ""))
            return {"action": action, "tokens_used": usage}
        except Exception:
            return None
