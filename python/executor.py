"""Policy executor — Tier 1 sequential replay (no post-replay policy loop)."""

from __future__ import annotations

import json
import os
from typing import Any

from embeddings import cosine, embed_state
from exa_client import get_page_schema

STATE_THRESHOLD = 0.82
MAX_STEPS = 25


def dedupe_actions(actions: list[dict]) -> list[dict]:
    """Drop empty clicks, blank navigates, and consecutive duplicate actions."""
    out: list[dict] = []
    prev_key: tuple | None = None
    for raw in actions:
        action = dict(raw)
        atype = action.get("type")
        if atype == "click" and not any(action.get(k) for k in ("text", "selector", "name")):
            continue
        if atype in ("type", "fill") and not (action.get("value") or action.get("text")):
            continue
        if atype == "navigate":
            url = action.get("url", "")
            if not url or url in ("about:blank", "about:newtab"):
                continue
        key = _action_key(action)
        if prev_key == key and atype in ("click", "navigate"):
            continue
        # Keep only the final keystroke snapshot for the same field
        if (
            atype in ("type", "fill")
            and out
            and out[-1].get("type") in ("type", "fill")
            and out[-1].get("selector") == action.get("selector")
            and out[-1].get("name") == action.get("name")
        ):
            out[-1] = action
            prev_key = key
            continue
        prev_key = key
        out.append(action)
    return out


def _action_key(action: dict) -> tuple:
    return (
        action.get("type"),
        action.get("text"),
        action.get("selector"),
        action.get("name"),
        action.get("url"),
        action.get("value"),
    )


def _primary_host(actions: list[dict]) -> str | None:
    from collections import Counter
    from urllib.parse import urlparse

    hosts: list[str] = []
    for action in actions:
        url = action.get("url") or ""
        if url.startswith("http"):
            host = urlparse(url).netloc.replace("www.", "")
            if host:
                hosts.append(host)
        sel = f"{action.get('selector') or ''}{action.get('name') or ''}"
        if "youtube" in sel or "search_query" in sel:
            hosts.append("youtube.com")
    if not hosts:
        return None
    return Counter(hosts).most_common(1)[0][0]


def normalize_actions_for_replay(actions: list[dict]) -> list[dict]:
    """Drop noisy cross-site navigates and redundant YouTube chrome clicks."""
    actions = dedupe_actions(actions)
    primary = _primary_host(actions)
    if primary and "youtube" in primary:
        cleaned: list[dict] = []
        for action in actions:
            if action.get("type") == "navigate":
                url = action.get("url") or ""
                if url and "youtube.com" not in url and "youtu.be" not in url:
                    continue
            cleaned.append(action)
        actions = cleaned

        has_search_type = any(
            action.get("type") in ("type", "fill")
            and (
                "search_query" in (action.get("selector") or "")
                or action.get("name") == "search_query"
            )
            for action in actions
        )
        if has_search_type:
            actions = [
                action
                for action in actions
                if not (
                    action.get("type") == "click"
                    and (
                        (action.get("selector") or "")
                        in ("#search-button-narrow", "#search-icon-legacy", "#search")
                        or action.get("name") == "search-button-narrow"
                        or (action.get("text") or "").strip().lower() == "search"
                    )
                )
            ]
    return actions


def _actions_from_policy(workflow: dict[str, Any]) -> list[dict]:
    """Rebuild ordered actions from policy graph for older workflow files."""
    policy = workflow.get("policy", {})
    if not policy:
        return []
    try:
        start = min(policy.keys(), key=lambda k: int(k) if str(k).isdigit() else 0)
    except ValueError:
        start = next(iter(policy))
    actions: list[dict] = []
    seen: set[str] = set()
    cur: str | None = str(start)
    while cur and cur not in seen and cur in policy:
        seen.add(cur)
        entry = policy[cur]
        action = entry.get("action", {})
        if action.get("type"):
            actions.append(dict(action))
        nxt = str(entry.get("next", ""))
        cur = nxt if nxt in policy else None
    return dedupe_actions(actions)


class PolicyExecutor:
    def __init__(self, workflow: dict[str, Any], params: dict[str, str] | None = None):
        self.workflow = workflow
        self.policy = workflow.get("policy", {})
        self.nodes = workflow.get("nodes", {})
        raw_actions = workflow.get("actions") or _actions_from_policy(workflow)
        self.ordered_actions: list[dict] = normalize_actions_for_replay(raw_actions)
        self.params = params or {}
        self.tokens = 0
        self.tier_log: list[int] = []
        self.step_index = 0
        self.replay_index = 0
        self.current_node: str | None = None
        self.replay_only = bool(self.ordered_actions)

    async def next_action(
        self,
        url: str,
        title: str,
        accessibility_tree: Any,
        *,
        last_action_ok: bool | None = None,
    ) -> dict[str, Any]:
        """Return next action for Swift to perform on WKWebView."""
        # Tier 1 — replay recorded actions in order (primary path)
        while self.replay_index < len(self.ordered_actions):
            action = self._templatize(dict(self.ordered_actions[self.replay_index]))
            self.replay_index += 1
            if action.get("type") == "navigate" and action.get("url") and url:
                if self._same_page(action["url"], url):
                    continue
            self.tier_log.append(1)
            self.step_index += 1
            return {
                "done": False,
                "tier": 1,
                "tokens": self.tokens,
                "action": action,
                "mode": "replay",
                "step": self.replay_index,
                "total": len(self.ordered_actions),
            }

        if self.replay_only:
            return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "replay_complete"}

        # Legacy workflows without recorded actions — one-shot policy match (no loop)
        if self.step_index >= MAX_STEPS:
            return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "max_steps"}

        state_emb = await embed_state(url, title, accessibility_tree)
        best_nid, best_sim = None, -1.0
        for nid, node in self.nodes.items():
            emb = node.get("emb") or node.get("state_emb")
            if emb:
                sim = cosine(state_emb, emb)
                if sim > best_sim:
                    best_sim, best_nid = sim, nid

        if best_nid and best_sim >= STATE_THRESHOLD and best_nid in self.policy:
            self.current_node = best_nid
            entry = self.policy[best_nid]
            action = self._templatize(entry.get("action", {}))
            if action.get("type"):
                self.tier_log.append(1)
                self.step_index += 1
                self.replay_only = True  # never match policy twice
                return {
                    "done": False,
                    "tier": 1,
                    "tokens": self.tokens,
                    "action": action,
                    "sim": round(best_sim, 3),
                    "mode": "policy_match",
                }

        tier2 = await self._fireworks_action(url, title, accessibility_tree)
        if tier2:
            self.tokens += tier2.get("tokens_used", 200)
            self.tier_log.append(2)
            self.step_index += 1
            self.replay_only = True
            return {
                "done": False,
                "tier": 2,
                "tokens": self.tokens,
                "action": tier2["action"],
            }

        tier3 = await self._minimax_action(url, title, accessibility_tree)
        if tier3:
            self.tokens += tier3.get("tokens_used", 800)
            self.tier_log.append(3)
            self.step_index += 1
            self.replay_only = True
            return {
                "done": False,
                "tier": 3,
                "tokens": self.tokens,
                "action": tier3["action"],
            }

        return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "no_action"}

    @staticmethod
    def _same_page(target: str, current: str) -> bool:
        from urllib.parse import urlparse

        try:
            t, c = urlparse(target), urlparse(current)
            return t.netloc == c.netloc and t.path.rstrip("/") == c.path.rstrip("/")
        except Exception:
            return target.rstrip("/") == current.rstrip("/")

    def _templatize(self, action: dict) -> dict:
        out = dict(action)
        for field in ("text", "value", "name", "url"):
            val = out.get(field)
            if isinstance(val, str):
                for k, v in self.params.items():
                    val = val.replace(f"{{{k}}}", str(v))
                out[field] = val
        return out

    async def _fireworks_action(self, url: str, title: str, tree: Any) -> dict | None:
        api_key = os.environ.get("FIREWORKS_API_KEY")
        if not api_key:
            return None

        from openai import AsyncOpenAI

        client = AsyncOpenAI(base_url="https://api.fireworks.ai/inference/v1", api_key=api_key)
        schema = await get_page_schema(url)
        prompt = (
            f"URL: {url}\nTitle: {title}\nSchema: {schema[:500]}\n"
            f"Elements: {json.dumps(tree, default=str)[:1500]}\n"
            'Return JSON only: {"type":"click","text":"Search"} or {"type":"type","name":"q","value":"text"}'
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
            'Next action JSON: {"type":"click","text":"Submit"}'
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
