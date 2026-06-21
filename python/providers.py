"""Interchangeable LLM / embedding provider adapters."""

from __future__ import annotations

import json
import os
from typing import Any

from embeddings import embed_element, embed_state


async def embed_page_state(url: str, title: str, tree: Any) -> list[float]:
    return await embed_state(url, title, tree)


async def embed_selected_element(el: dict) -> list[float]:
    return await embed_element(
        el.get("text") or el.get("label") or "",
        el.get("role") or "",
        el.get("ref") or "",
    )


async def expert_action(
    task: dict,
    url: str,
    title: str,
    candidates: list[dict],
) -> tuple[dict | None, str, str]:
    """Returns (action_dict, raw_output, provider_name)."""
    from agent_llm import llm_next_action
    from executor import _action_from_ref

    summary = {"url": url, "title": title, "text": ""}
    try:
        action, meta = await llm_next_action(task, summary, candidates, [], 0)
        replay = _action_from_ref(action, candidates)
        if replay:
            provider = meta.get("provider") or meta.get("source") or "llm"
            return replay, meta.get("raw", ""), provider
    except Exception:
        pass

    prompt = _expert_prompt(task, url, title, candidates)
    action, raw, provider = await _openai_expert(prompt)
    if action:
        return action, raw, provider
    action, raw, provider = await _fireworks_deepseek(prompt)
    if action:
        return action, raw, provider
    return await _minimax_expert(prompt)


async def fast_action(url: str, title: str, candidates: list[dict], schema: str = "") -> tuple[dict | None, int]:
    """Tier 2 fast model."""
    from openai import AsyncOpenAI

    prompt = (
        f"URL: {url}\nTitle: {title}\nSchema: {schema[:500]}\n"
        f"Elements: {json.dumps(candidates[:25], default=str)[:1500]}\n"
        'Return JSON only: {"action":"click","ref":"e0"} or {"action":"type","ref":"e1","value":"text"}'
    )

    if os.environ.get("OPENAI_API_KEY"):
        client = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
        model = os.environ.get("OPENHIVE_T2_MODEL", "gpt-4o-mini")
    elif os.environ.get("FIREWORKS_API_KEY"):
        client = AsyncOpenAI(
            base_url="https://api.fireworks.ai/inference/v1",
            api_key=os.environ["FIREWORKS_API_KEY"],
        )
        model = os.environ.get("OPENHIVE_T2_MODEL", "accounts/fireworks/models/llama-v3p1-8b-instruct")
    else:
        return None, 0

    try:
        kwargs: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": 80,
        }
        if os.environ.get("OPENAI_API_KEY"):
            kwargs["response_format"] = {"type": "json_object"}
        r = await client.chat.completions.create(**kwargs)
        text = r.choices[0].message.content or "{}"
        usage = r.usage.total_tokens if r.usage else 200
        action = _parse_action_json(text)
        return action, usage
    except Exception:
        return None, 0


def _expert_prompt(task: dict, url: str, title: str, candidates: list[dict]) -> str:
    return (
        f"Task: {json.dumps(task)}\nURL: {url}\nTitle: {title}\n"
        f"Candidates:\n{json.dumps(candidates[:40], indent=2)[:6000]}\n"
        'Return strict JSON: {"action":"click|type","ref":"eN","value":"..."}'
    )


async def _openai_expert(prompt: str) -> tuple[dict | None, str, str]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return None, "", ""
    from openai import AsyncOpenAI

    client = AsyncOpenAI(api_key=api_key)
    model = os.environ.get("OPENHIVE_EXPERT_MODEL") or "gpt-4o-mini"
    try:
        r = await client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
            max_tokens=120,
            response_format={"type": "json_object"},
        )
        raw = r.choices[0].message.content or ""
        return _parse_action_json(raw), raw, f"openai/{model}"
    except Exception:
        return None, "", ""


async def _fireworks_deepseek(prompt: str) -> tuple[dict | None, str, str]:
    api_key = os.environ.get("FIREWORKS_API_KEY")
    if not api_key:
        return None, "", ""
    from openai import AsyncOpenAI

    client = AsyncOpenAI(base_url="https://api.fireworks.ai/inference/v1", api_key=api_key)
    model = os.environ.get("OPENHIVE_EXPERT_MODEL", "accounts/fireworks/models/deepseek-v3")
    try:
        r = await client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
            max_tokens=120,
        )
        raw = r.choices[0].message.content or ""
        return _parse_action_json(raw), raw, f"fireworks/{model}"
    except Exception:
        return None, "", ""


async def _minimax_expert(prompt: str) -> tuple[dict | None, str, str]:
    api_key = os.environ.get("MINIMAX_API_KEY") or os.environ.get("FIREWORKS_API_KEY")
    if not api_key:
        return None, "", ""
    from openai import AsyncOpenAI

    base = "https://api.minimaxi.chat/v1" if os.environ.get("MINIMAX_API_KEY") else "https://api.fireworks.ai/inference/v1"
    client = AsyncOpenAI(base_url=base, api_key=api_key)
    model = os.environ.get("OPENHIVE_FALLBACK_MODEL", "MiniMax-Text-01")
    try:
        r = await client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
            max_tokens=120,
        )
        raw = r.choices[0].message.content or ""
        return _parse_action_json(raw), raw, f"fallback/{model}"
    except Exception:
        return None, "", ""


def _parse_action_json(text: str) -> dict | None:
    cleaned = text.strip().strip("`").replace("json", "").strip()
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start < 0 or end <= start:
            return None
        try:
            data = json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError:
            return None
    if "action" in data and "type" not in data:
        data["type"] = data.pop("action")
    return data if data.get("type") in ("click", "type", "press", "navigate", "done") else None


def deterministic_fallback(task: dict, candidates: list[dict]) -> dict | None:
    """Local rule when expert returns invalid JSON — e.g. type origin into first likely field."""
    goal = str(task.get("goal") or "")
    origin = task.get("origin") or task.get("departDate") or ""
    dest = task.get("destination") or ""
    value = str(origin or dest or goal[:40] or "")
    if not value:
        return None
    for c in candidates:
        text = (c.get("text") or c.get("label") or "").lower()
        role = (c.get("role") or "").lower()
        if "from" in text or "origin" in text or role in ("combobox", "textbox", "searchbox"):
            return {"type": "type", "ref": c.get("ref", "e0"), "value": value}
    if candidates:
        return {"type": "type", "ref": candidates[0].get("ref", "e0"), "value": value}
    return None
