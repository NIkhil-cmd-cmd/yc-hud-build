"""LLM-powered browser agent — picks any configured provider (OpenAI, OpenRouter, Fireworks, MiniMax)."""

from __future__ import annotations

import json
import os
import re
from typing import Any

from log_config import log_event, setup_logging

log = setup_logging("openhive.agent_llm")

ALLOWED_ACTIONS = frozenset(
    {"click", "click_date", "next_month", "click_xy", "type", "press", "done", "navigate"}
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


def pick_llm_config() -> tuple[Any, str, str] | None:
    """Return (async_client, model, provider_label) or None."""
    from openai import AsyncOpenAI

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
    return (
        "You are a browser automation agent controlling a real web page via element refs. "
        "Return ONLY valid JSON — no markdown, no explanation. "
        "Pick exactly ONE next action to progress the task."
    )


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

    return (
        f"Task: {_task_prompt(task)}\n"
        f"Step: {step_index}\n"
        f"Current page:\n{json.dumps(summary, default=str)[:4000]}\n"
        f"Recent actions: {json.dumps(history[-8:], default=str)[:2000]}\n"
        f"Interactive elements (use ref exactly as shown):\n{json.dumps(compact_candidates, default=str)[:8000]}\n\n"
        "Allowed action JSON shapes:\n"
        '{"action":"click","ref":"e3","value":null}\n'
        '{"action":"type","ref":"e1","value":"BOS"}\n'
        '{"action":"press","ref":null,"value":"Enter"}\n'
        '{"action":"navigate","ref":null,"value":"https://example.com"}\n'
        '{"action":"done","ref":null,"value":null}\n\n'
        "Rules:\n"
        "- Use refs from the candidate list only.\n"
        "- For autocomplete dropdowns, type then press Enter or click the matching option.\n"
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

    refs = {c.get("ref") for c in candidates if c.get("ref")}

    if kind == "done":
        return
    if kind == "navigate":
        url = action.get("value") or action.get("url")
        if not url or not str(url).startswith("http"):
            raise ValueError("navigate requires http(s) url in value")
        return
    if kind == "press":
        return
    if kind == "click_xy":
        if not isinstance(action.get("x"), (int, float)) or not isinstance(action.get("y"), (int, float)):
            raise ValueError("click_xy requires numeric x/y")
        return

    ref = action.get("ref")
    if ref and ref not in refs:
        raise ValueError(f"Invalid ref {ref!r} — not in current candidates")
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
    cfg = pick_llm_config()
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
