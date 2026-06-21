"""LLM-powered browser agent — picks any configured provider (OpenAI, OpenRouter, Fireworks, MiniMax)."""

from __future__ import annotations

import json
import os
import re
from typing import Any

from browser_use_runner import OPENHIVE_SYSTEM_EXTENSION
from log_config import log_event, setup_logging

log = setup_logging("openhive.agent_llm")

ALLOWED_ACTIONS = frozenset(
    {
        "click", "click_date", "next_month", "click_xy", "click_option", "type", "press", "done",
        "navigate", "search", "new_tab", "switch_tab", "close_tab",
        "scroll", "scroll_into_view", "select",
        "go_back", "go_forward", "reload",
        "hover", "check", "uncheck", "dblclick", "double_click",
        "wait", "wait_for", "extract", "evaluate", "eval", "upload",
        "mcp_call",
    }
)


def agent_expert_mode() -> str:
    """auto | llm | scripted — auto uses LLM when any API key is present."""
    return (os.getenv("OPENHIVE_AGENT_EXPERT") or "auto").strip().lower()


def llm_available() -> bool:
    return bool(
        os.getenv("OPENAI_API_KEY")
        or os.getenv("OPENROUTER_API_KEY")
        or os.getenv("FIREWORKS_API_KEY")
        or os.getenv("MINIMAX_API_KEY")
    )


def pick_llm_config(
    provider: str | None = None,
    model: str | None = None,
) -> tuple[Any, str, str] | None:
    """Return (async_client, model, provider_label) or None."""
    from openai import AsyncOpenAI

    def _client(api_key: str, base_url: str | None = None) -> AsyncOpenAI:
        if base_url:
            return AsyncOpenAI(api_key=api_key, base_url=base_url)
        return AsyncOpenAI(api_key=api_key)

    if provider:
        p = provider.strip().lower()
        if p == "openai" and (key := os.getenv("OPENAI_API_KEY")):
            m = model or os.getenv("OPENHIVE_AGENT_MODEL") or os.getenv("OPENAI_AGENT_MODEL") or "gpt-4o-mini"
            return _client(key), m, "openai"
        if p in ("openrouter", "claude", "deepseek", "llama", "gemini") and (key := os.getenv("OPENROUTER_API_KEY")):
            defaults = {
                "claude": "anthropic/claude-sonnet-4.5",
                "deepseek": "deepseek/deepseek-chat-v3.1:free",
                "llama": "meta-llama/llama-4-scout:free",
                "gemini": "google/gemini-2.0-flash-001",
                "openrouter": "openai/gpt-4o-mini",
            }
            m = model or defaults.get(p) or "openai/gpt-4o-mini"
            return _client(key, "https://openrouter.ai/api/v1"), m, "openrouter"
        if p == "minimax" and (key := os.getenv("MINIMAX_API_KEY")):
            m = model or os.getenv("OPENHIVE_AGENT_MODEL") or "MiniMax-Text-01"
            return _client(key, "https://api.minimaxi.chat/v1"), m, "minimax"
        if p == "fireworks" and (key := os.getenv("FIREWORKS_API_KEY")):
            m = model or os.getenv("OPENHIVE_AGENT_MODEL") or os.getenv("FIREWORKS_MODEL") or "accounts/fireworks/models/gpt-oss-120b"
            return _client(key, "https://api.fireworks.ai/inference/v1"), m, "fireworks"
        if p == "ollama":
            host = (os.getenv("OLLAMA_HOST") or "http://localhost:11434").rstrip("/")
            m = model or os.getenv("OPENHIVE_AGENT_MODEL") or "llama3.2"
            return _client("ollama", f"{host}/v1"), m, "ollama"
        if p == "exa":
            if key := os.getenv("OPENAI_API_KEY"):
                m = model or "gpt-4o-mini"
                return _client(key), m, "exa"
            if key := os.getenv("OPENROUTER_API_KEY"):
                m = model or "openai/gpt-4o-mini"
                return _client(key, "https://openrouter.ai/api/v1"), m, "exa"

    if key := os.getenv("OPENAI_API_KEY"):
        model = os.getenv("OPENHIVE_AGENT_MODEL") or os.getenv("OPENAI_AGENT_MODEL") or "gpt-4o-mini"
        return AsyncOpenAI(api_key=key), model, "openai"

    if key := os.getenv("OPENROUTER_API_KEY"):
        model = os.getenv("OPENHIVE_AGENT_MODEL") or "openai/gpt-4o-mini"
        return (
            AsyncOpenAI(api_key=key, base_url="https://openrouter.ai/api/v1"),
            model,
            "openrouter",
        )

    if key := os.getenv("FIREWORKS_API_KEY"):
        model = os.getenv("OPENHIVE_AGENT_MODEL") or os.getenv("FIREWORKS_MODEL") or "accounts/fireworks/models/gpt-oss-120b"
        return (
            AsyncOpenAI(api_key=key, base_url="https://api.fireworks.ai/inference/v1"),
            model,
            "fireworks",
        )

    if key := os.getenv("MINIMAX_API_KEY"):
        model = os.getenv("OPENHIVE_AGENT_MODEL") or "MiniMax-Text-01"
        return AsyncOpenAI(api_key=key, base_url="https://api.minimaxi.chat/v1"), model, "minimax"

    return None


def _task_prompt(task: dict[str, Any]) -> str:
    if task.get("goal"):
        return str(task["goal"])
    if task.get("origin") and task.get("destination"):
        return (
            f"Book a one-way flight from {task['origin']} to {task['destination']} "
            f"departing {task.get('departDate', '')}. Submit search and stop when flight results are visible."
        )
    return json.dumps(task)


def _system_prompt() -> str:
    base = (
        "You are a browser automation agent controlling a real web page via element refs (e0, e1, e2, …). "
        "Return ONLY valid JSON — no markdown, no explanation. "
        "Pick exactly ONE next action to progress the task."
    )
    return base + OPENHIVE_SYSTEM_EXTENSION


def _user_prompt(
    task: dict[str, Any],
    summary: dict[str, Any],
    candidates: list[dict[str, Any]],
    history: list[dict[str, Any]],
    step_index: int,
) -> str:
    compact_candidates = []
    for c in candidates[:50]:
        compact_candidates.append(
            {
                "ref": c.get("ref"),
                "tag": c.get("tag"),
                "role": c.get("role"),
                "text": (c.get("text") or c.get("ariaLabel") or c.get("placeholder") or "")[:120],
                "placeholder": c.get("placeholder"),
                "ariaLabel": c.get("ariaLabel"),
            }
        )

    mcp_tools = task.get("mcpTools") or []
    mcp_block = ""
    if mcp_tools:
        compact_mcp = [
            {
                "name": t.get("name"),
                "description": (t.get("description") or "")[:200],
            }
            for t in mcp_tools[:30]
        ]
        mcp_block = (
            f"\nConnected app tools (use mcp_call when the task needs email, GitHub, Notion, etc.):\n"
            f"{json.dumps(compact_mcp, default=str)[:4000]}\n"
            '{"action":"mcp_call","server":"github","tool":"create_issue","arguments":{"title":"Bug","body":"..."}}\n'
        )

    return (
        f"Task: {_task_prompt(task)}\n"
        f"Step: {step_index}\n"
        f"Current page:\n{json.dumps(summary, default=str)[:4000]}\n"
        f"Recent actions: {json.dumps(history[-8:], default=str)[:2000]}\n"
        f"Interactive elements (use ref exactly as shown):\n{json.dumps(compact_candidates, default=str)[:8000]}\n"
        f"{mcp_block}\n"
        "Allowed action JSON shapes:\n"
        '{"action":"search","ref":null,"value":"your search query"}\n'
        '{"action":"navigate","ref":null,"value":"https://example.com"}\n'
        '{"action":"new_tab","ref":null,"value":"https://example.com"}\n'
        '{"action":"click","ref":"e3","value":null}\n'
        '{"action":"type","ref":"e1","value":"BOS"}\n'
        '{"action":"press","ref":null,"value":"Enter"}\n'
        '{"action":"scroll","ref":null,"value":"down"}\n'
        '{"action":"click_option","ref":null,"value":"Boston BOS"}\n'
        '{"action":"hover","ref":"e2","value":null}\n'
        '{"action":"check","ref":"e4","value":null}\n'
        '{"action":"wait","ref":"e3","value":null}\n'
        '{"action":"go_back","ref":null,"value":null}\n'
        '{"action":"switch_tab","ref":null,"value":"0"}\n'
        '{"action":"extract","ref":"e1","value":null}\n'
        '{"action":"done","ref":null,"value":null}\n\n'
        "Rules:\n"
        "- Prefer search for lookup/research tasks (faster than typing into Google manually).\n"
        "- After typing in autocomplete fields, use click_option with the matching suggestion text.\n"
        "- Use wait when the page is loading or a dropdown has not appeared yet.\n"
        "- Use hover before clicking menu items that need mouseenter.\n"
        "- Use airport codes for flight origin/destination.\n"
        "- Return done only when the task is visibly complete on the page.\n"
        "- Prefer type over click for text fields; click for buttons and options."
    )


def parse_action_json(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("LLM did not return JSON")
        data = json.loads(cleaned[start : end + 1])
    if not isinstance(data, dict):
        raise ValueError("LLM JSON must be an object")
    if "action" in data and "type" not in data:
        data["type"] = data["action"]
    return data


def validate_action(action: dict[str, Any], candidates: list[dict[str, Any]]) -> None:
    kind = action.get("action") or action.get("type")
    if kind not in ALLOWED_ACTIONS:
        raise ValueError(f"Invalid action type: {kind!r}")

    if kind in {
        "done", "navigate", "search", "new_tab", "scroll", "select", "press",
        "go_back", "go_forward", "reload", "switch_tab", "close_tab",
        "wait", "wait_for", "click_option", "evaluate", "eval", "upload",
        "hover", "check", "uncheck", "dblclick", "double_click",
        "scroll_into_view", "scrollintoview", "extract", "mcp_call",
    }:
        if kind == "mcp_call":
            if not action.get("server") and not action.get("namespace"):
                raise ValueError("mcp_call requires server namespace")
            if not action.get("tool"):
                raise ValueError("mcp_call requires tool name")
            return
        if kind == "navigate":
            url = action.get("value") or action.get("url")
            if not url or not str(url).startswith("http"):
                raise ValueError("navigate requires http(s) url in value")
        if kind == "search":
            q = action.get("value") or action.get("query")
            if not q or not str(q).strip():
                raise ValueError("search requires query in value")
        if kind == "click_option":
            q = action.get("value") or action.get("text")
            if not q or not str(q).strip():
                raise ValueError("click_option requires option text in value")
        if kind == "click_xy":
            if not isinstance(action.get("x"), (int, float)) or not isinstance(action.get("y"), (int, float)):
                raise ValueError("click_xy requires numeric x/y")
        return

    refs = {c.get("ref") for c in candidates if c.get("ref")}
    normalized_refs = refs | {r.lstrip("@") for r in refs if isinstance(r, str)}

    ref = action.get("ref")
    if ref and isinstance(ref, str):
        ref_norm = ref.lstrip("@")
        if ref not in refs and ref_norm not in normalized_refs:
            raise ValueError(f"Invalid ref {ref!r} — not in current candidates")
        if ref.startswith("@"):
            action["ref"] = ref_norm
    if kind == "type" and not isinstance(action.get("value"), str):
        raise ValueError("type action requires string value")


async def llm_next_action(
    task: dict[str, Any],
    summary: dict[str, Any],
    candidates: list[dict[str, Any]],
    history: list[dict[str, Any]],
    step_index: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Call the best available LLM for the next browser action."""
    provider_override = task.get("agentProvider")
    model_override = task.get("agentModel")
    cfg = pick_llm_config(provider_override, model_override)
    if not cfg:
        raise RuntimeError("No LLM API key configured (set OPENAI_API_KEY, OPENROUTER_API_KEY, FIREWORKS_API_KEY, or MINIMAX_API_KEY)")

    client, model, provider = cfg
    messages = [
        {"role": "system", "content": _system_prompt()},
        {
            "role": "user",
            "content": _user_prompt(task, summary, candidates, history, step_index),
        },
    ]

    if provider == "exa" or provider_override == "exa":
        goal = str(task.get("goal") or "").strip()
        if step_index == 0 and goal:
            from exa_client import exa_answer

            exa_ctx = await exa_answer(goal)
            if exa_ctx:
                messages[1]["content"] += f"\n\nExa research context:\n{exa_ctx[:3000]}"
        provider = "exa"

    kwargs: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": 0,
        "max_tokens": 512,
    }
    # OpenAI supports json_object; OpenRouter/Fireworks may too
    if provider in ("openai", "openrouter"):
        kwargs["response_format"] = {"type": "json_object"}

    log_event(log, "llm_request", provider=provider, model=model, step=step_index)
    response = await client.chat.completions.create(**kwargs)
    raw = response.choices[0].message.content or ""
    action = parse_action_json(raw)
    validate_action(action, candidates)

    usage = {}
    if response.usage:
        usage = {
            "prompt_tokens": response.usage.prompt_tokens,
            "completion_tokens": response.usage.completion_tokens,
            "total_tokens": response.usage.total_tokens,
        }

    meta = {
        "provider": provider,
        "model": model,
        "raw": raw[:500],
        "usage": usage,
    }
    log_event(log, "llm_action", provider=provider, action=action.get("action") or action.get("type"), ref=action.get("ref"))
    return action, meta


async def choose_next_action(
    task: dict[str, Any],
    summary: dict[str, Any],
    candidates: list[dict[str, Any]],
    history: list[dict[str, Any]],
    step_index: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """LLM first (when enabled), then scripted/deterministic fallbacks."""
    mode = agent_expert_mode()
    use_llm = mode == "llm" or (mode == "auto" and llm_available())

    # Fast path: research/search tasks on blank or Google homepage → one-shot search
    if step_index == 0 and not history:
        goal = str(task.get("goal") or "").strip()
        url = str(summary.get("url") or "")
        on_start_page = not url or url.startswith("about:") or "google.com" in url
        if goal and on_start_page and _looks_like_search_task(goal):
            return (
                {"action": "search", "value": _search_query_from_goal(goal)},
                {"source": "nook_search", "model": "native-browser"},
            )

    if use_llm:
        try:
            action, meta = await llm_next_action(task, summary, candidates, history, step_index)
            meta["source"] = "llm"
            return action, meta
        except Exception as exc:
            log_event(log, "llm_fallback", error=str(exc)[:200], step=step_index)

    # Google Flights scripted expert (proven smoke path)
    if task.get("origin") and task.get("destination"):
        from smoke.run_local_browser_trace_gate import scripted_action

        action = scripted_action(task, candidates, history)
        return action, {"source": "scripted", "model": "scripted-google-flights-expert"}

    from providers import deterministic_fallback

    fb = deterministic_fallback(task, candidates)
    if fb:
        return {**fb, "action": fb.get("type", "type")}, {"source": "deterministic_fallback"}

    raise RuntimeError("No action available — configure OPENAI_API_KEY or provide a clearer task goal")


def _looks_like_search_task(goal: str) -> bool:
    lower = goal.lower()
    triggers = ("search", "find", "look up", "lookup", "google", "youtube", "research")
    return any(t in lower for t in triggers)


def _search_query_from_goal(goal: str) -> str:
    """Strip command verbs so search gets the actual query."""
    q = goal.strip()
    for prefix in (
        "search for ",
        "search ",
        "find ",
        "look up ",
        "lookup ",
        "google ",
        "research ",
    ):
        if q.lower().startswith(prefix):
            q = q[len(prefix) :].strip()
            break
    return q or goal
