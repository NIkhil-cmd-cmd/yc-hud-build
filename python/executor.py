"""Policy executor — Tier 1/2/3 replay with embedding + geometry matching."""

from __future__ import annotations

import json
import os
from typing import Any

from embeddings import cosine, embed_element, embed_state
from exa_client import get_page_schema
from providers import expert_action, fast_action

STATE_THRESHOLD = 0.82
ELEMENT_THRESHOLD = 0.78
MAX_STEPS = 25
BBOX_PROXIMITY_PX = 80.0


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
        if not isinstance(self.policy, dict):
            self.policy = {}
        raw_nodes = workflow.get("nodes", {})
        if isinstance(raw_nodes, dict):
            self.nodes = raw_nodes
        elif isinstance(raw_nodes, list):
            self.nodes = {
                str(i): n for i, n in enumerate(raw_nodes) if isinstance(n, dict)
            }
        else:
            self.nodes = {}
        self.policy_nodes = workflow.get("policyNodes") or workflow.get("policy_nodes") or []
        if not isinstance(self.policy_nodes, list):
            self.policy_nodes = []
        raw_actions = workflow.get("actions") or _actions_from_policy(workflow)
        self.ordered_actions: list[dict] = normalize_actions_for_replay(raw_actions)
        self.params = params or {}
        self.tokens = 0
        self.tier_log: list[int] = []
        self.step_index = 0
        self._replay_cursor = 0
        self.current_node: str | None = None
        self.last_state_id: str | None = None
        self.mdp_path: list[str] = []
        self.replay_only = bool(self.ordered_actions)
        self._policy_loop = not bool(self.ordered_actions)
        self.skill_id = workflow.get("id", "")

    async def next_action(
        self,
        url: str,
        title: str,
        accessibility_tree: Any,
        *,
        last_action_ok: bool | None = None,
    ) -> dict[str, Any]:
        """Return next action for Swift to perform on WKWebView."""
        candidates = _extract_candidates(accessibility_tree)

        if last_action_ok is True:
            self._replay_cursor += 1

        # Tier 1 — replay recorded actions in order (primary path)
        while self._replay_cursor < len(self.ordered_actions):
            action = self._templatize(dict(self.ordered_actions[self._replay_cursor]))
            if action.get("type") == "navigate" and action.get("url") and url:
                if self._same_page(action["url"], url):
                    self._replay_cursor += 1
                    continue
            enriched = _enrich_stored_action(action, candidates)
            self.tier_log.append(1)
            self.step_index += 1
            state_id = str(self._replay_cursor)
            next_state_id = str(self._replay_cursor + 1)
            self.last_state_id = next_state_id
            self.mdp_path.append(next_state_id)
            return {
                "done": False,
                "tier": 1,
                "tokens": self.tokens,
                "action": enriched,
                "mode": "replay",
                "step": self._replay_cursor + 1,
                "total": len(self.ordered_actions),
                "stateId": state_id,
                "nextStateId": next_state_id,
                "skillId": self.skill_id,
            }

        if self.replay_only and not self._policy_loop:
            return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "replay_complete"}

        if self.step_index >= MAX_STEPS:
            return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "max_steps"}

        state_emb = await embed_state(url, title, accessibility_tree)

        # T1 — policy node match (embedding + element geometry)
        t1 = await self._tier1_policy_action(state_emb, url, candidates)
        if t1:
            self.tier_log.append(1)
            self.step_index += 1
            prev = self.last_state_id or "0"
            node_id = str(t1.pop("_nodeId", self.step_index))
            self.last_state_id = node_id
            self.mdp_path.append(node_id)
            return {
                **t1,
                "done": False,
                "tier": 1,
                "tokens": self.tokens,
                "mode": "policy_node",
                "stateId": prev,
                "nextStateId": node_id,
                "skillId": self.skill_id,
            }

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
                prev = self.last_state_id or "0"
                nxt = str(entry.get("next", best_nid))
                self.last_state_id = nxt
                self.mdp_path.append(nxt)
                self.tier_log.append(1)
                self.step_index += 1
                return {
                    "done": False,
                    "tier": 1,
                    "tokens": self.tokens,
                    "action": action,
                    "sim": round(best_sim, 3),
                    "mode": "policy_match",
                    "stateId": prev,
                    "nextStateId": nxt,
                    "skillId": self.skill_id,
                }

        tier2 = await self._tier2_action(url, title, candidates)
        if tier2:
            self.tokens += tier2.get("tokens_used", 200)
            self.tier_log.append(2)
            self.step_index += 1
            return {
                "done": False,
                "tier": 2,
                "tokens": self.tokens,
                "action": tier2["action"],
                "mode": "exa_fast",
            }

        tier3 = await self._tier3_expert(url, title, candidates)
        if tier3:
            self.tokens += tier3.get("tokens_used", 800)
            self.tier_log.append(3)
            self.step_index += 1
            return {
                "done": False,
                "tier": 3,
                "tokens": self.tokens,
                "action": tier3["action"],
                "mode": "expert",
            }

        return {"done": True, "tier": 0, "tokens": self.tokens, "reason": "no_action"}

    async def _tier1_policy_action(
        self, state_emb: list[float], url: str, candidates: list[dict]
    ) -> dict[str, Any] | None:
        if not self.policy_nodes:
            return None
        best_node = None
        best_sim = -1.0
        for node in self.policy_nodes:
            centroid = node.get("centroid") or []
            if not centroid:
                continue
            pattern = node.get("urlPattern") or ""
            if pattern and pattern not in _url_pattern(url):
                continue
            sim = cosine(state_emb, centroid)
            if sim > best_sim:
                best_sim, best_node = sim, node
        if not best_node or best_sim < STATE_THRESHOLD:
            return None
        actions = best_node.get("actions") or []
        if not actions:
            return None
        best_action = actions[0]
        matched = await _match_element(best_action, candidates)
        if matched:
            return {"action": matched, "sim": round(best_sim, 3), "_nodeId": best_node.get("id", 0)}
        return None

    async def _tier2_action(self, url: str, title: str, candidates: list[dict]) -> dict | None:
        schema = await get_page_schema(url)
        action, usage = await fast_action(url, title, candidates, schema)
        if not action:
            return None
        replay = _action_from_ref(action, candidates)
        if replay:
            return {"action": replay, "tokens_used": usage}
        return None

    async def _tier3_expert(self, url: str, title: str, candidates: list[dict]) -> dict | None:
        task = self.params or {"goal": self.workflow.get("name", "complete task")}
        action, _raw, _provider = await expert_action(task, url, title, candidates)
        if not action:
            return None
        replay = _action_from_ref(action, candidates)
        if replay:
            return {"action": replay, "tokens_used": 800}
        return None

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


def _url_pattern(url: str) -> str:
    from urllib.parse import urlparse

    p = urlparse(url)
    return f"{p.netloc}{p.path.rstrip('/')}"


def _extract_candidates(tree: Any) -> list[dict]:
    if isinstance(tree, dict):
        elements = tree.get("elements") or tree.get("candidates") or []
        if elements:
            return [dict(e) for e in elements]
    if isinstance(tree, list):
        return [dict(e) for e in tree]
    return []


def _action_from_ref(action: dict, candidates: list[dict]) -> dict | None:
    atype = action.get("type") or action.get("action")
    if not atype:
        return None
    ref = action.get("ref", "")
    selected = next((c for c in candidates if c.get("ref") == ref), None)
    out: dict[str, Any] = {"type": atype}
    if atype == "type":
        out["value"] = action.get("value", "")
    if selected:
        out["text"] = selected.get("text") or selected.get("label") or ""
        out["selector"] = selected.get("selector") or ""
        out["name"] = selected.get("name") or ""
        out["ref"] = ref
    elif action.get("text"):
        out["text"] = action["text"]
    elif action.get("selector"):
        out["selector"] = action["selector"]
    return out


def _enrich_stored_action(stored: dict, candidates: list[dict]) -> dict:
    """Attach live refs/coordinates from the current page for reliable replay."""
    out = dict(stored)
    ref = stored.get("ref", "")
    if ref:
        selected = next((c for c in candidates if c.get("ref") == ref), None)
        if selected:
            out["ref"] = ref
            out["text"] = selected.get("text") or selected.get("ariaLabel") or out.get("text", "")
            out["selector"] = selected.get("selector") or out.get("selector", "")
            out["name"] = selected.get("name") or out.get("name", "")
            bbox = selected.get("bbox") or {}
            w, h = bbox.get("width") or 0, bbox.get("height") or 0
            if w > 0 and h > 0:
                out["x"] = bbox.get("x", 0) + w / 2
                out["y"] = bbox.get("y", 0) + h / 2
            return out

    # Fallback: match by stored label/selector on the live page
    needle = (stored.get("text") or stored.get("name") or "").strip().lower()
    if needle:
        for candidate in candidates:
            label = " ".join(
                str(candidate.get(k) or "")
                for k in ("text", "ariaLabel", "placeholder", "name")
            ).lower()
            if needle in label or label in needle:
                out["ref"] = candidate.get("ref", "")
                out["text"] = candidate.get("text") or candidate.get("ariaLabel") or needle
                out["selector"] = candidate.get("selector") or out.get("selector", "")
                bbox = candidate.get("bbox") or {}
                w, h = bbox.get("width") or 0, bbox.get("height") or 0
                if w > 0 and h > 0:
                    out["x"] = bbox.get("x", 0) + w / 2
                    out["y"] = bbox.get("y", 0) + h / 2
                break
    return out


async def _match_element(stored: dict, candidates: list[dict]) -> dict | None:
    ref = stored.get("ref", "")
    el_centroid = stored.get("elementCentroid") or []
    stored_text = (stored.get("value") or stored.get("text") or "").lower()

    best: dict | None = None
    best_score = -1.0
    for c in candidates:
        score = 0.0
        if ref and c.get("ref") == ref:
            score += 2.0
        if stored_text and stored_text in (c.get("text") or "").lower():
            score += 1.0
        if el_centroid:
            cand_emb = await embed_element(c.get("text") or "", c.get("role") or "", c.get("ref") or "")
            score += cosine(el_centroid, cand_emb)
        if score > best_score:
            best_score, best = score, c

    if not best:
        best = next((c for c in candidates if c.get("ref") == ref), None)
    if not best:
        return None

    atype = stored.get("type", "click")
    out: dict[str, Any] = {
        "type": atype,
        "text": best.get("text") or best.get("label") or "",
        "selector": best.get("selector") or "",
        "name": best.get("name") or "",
        "ref": best.get("ref") or ref,
    }
    if atype in ("type", "fill"):
        out["value"] = stored.get("value", "")
    return out
