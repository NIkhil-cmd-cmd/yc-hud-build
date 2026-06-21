"""MDP-guided lightweight verifier.

The Markov/MDP layer (scripted_action or PolicyExecutor) proposes the next
action. Before we actually fire it, a small/cheap LLM (gpt-4o-mini by default)
VERIFIES that the live page is ready for that exact action and that its target
element is really present right now.

It deliberately does NOT plan the whole task. It can only return:
  - proceed  → do the recorded action now (optionally remap `ref` to the live
               candidate that actually matches the intended target)
  - wait     → page is still loading / dropdown not open / target missing; the
               caller should re-snapshot the page and ask again instead of
               blindly firing the next step

This keeps the recorded Markov trajectory in charge (it decides *what* to do)
while preventing the "fire every step blindly, far too fast, without looking at
the page" failure mode.

Disable with OPENHIVE_MDP_VERIFY=0. Override the model with
OPENHIVE_VERIFIER_MODEL (defaults to a mini model).
"""

from __future__ import annotations

import json
import os
from typing import Any

from agent_llm import pick_llm_config
from log_config import log_event, setup_logging

log = setup_logging("openhive.mdp_guided")

# Actions that don't target an on-page element — no point asking the LLM.
_NO_VERIFY_KINDS = frozenset(
    {
        "navigate", "press", "done", "search", "scroll", "go_back",
        "go_forward", "reload", "wait", "wait_for", "click_xy", "mcp_call",
        "new_tab", "switch_tab", "close_tab",
    }
)


def verifier_enabled() -> bool:
    return os.getenv("OPENHIVE_MDP_VERIFY", "1").strip().lower() not in ("0", "false", "no", "off")


def _verifier_model(provider: str) -> str:
    override = os.getenv("OPENHIVE_VERIFIER_MODEL")
    if override:
        return override
    return {
        "openrouter": "openai/gpt-4o-mini",
        "fireworks": "accounts/fireworks/models/gpt-oss-120b",
        "minimax": "MiniMax-Text-01",
    }.get(provider, "gpt-4o-mini")


def needs_verification(kind: str, action: dict[str, Any]) -> bool:
    if not verifier_enabled():
        return False
    if kind in _NO_VERIFY_KINDS:
        return False
    # Only worth checking when the action aims at an element.
    return bool(action.get("ref")) or kind in {
        "click", "type", "click_date", "next_month", "select", "hover",
        "check", "uncheck", "dblclick", "double_click", "click_option",
    }


def _recommended_target(recommended: dict[str, Any], candidates: list[dict[str, Any]]) -> str:
    ref = recommended.get("ref")
    if ref:
        match = next((c for c in candidates if c.get("ref") == ref), None)
        if match:
            return (
                match.get("text")
                or match.get("ariaLabel")
                or match.get("placeholder")
                or ""
            )[:120]
    return str(recommended.get("text") or recommended.get("value") or "")[:120]


def _compact_candidates(candidates: list[dict[str, Any]], limit: int = 40) -> list[dict[str, Any]]:
    out = []
    for c in candidates[:limit]:
        out.append(
            {
                "ref": c.get("ref"),
                "role": c.get("role") or c.get("tag"),
                "text": (
                    c.get("text")
                    or c.get("ariaLabel")
                    or c.get("placeholder")
                    or ""
                )[:80],
            }
        )
    return out


async def verify_recommendation(
    task: dict[str, Any],
    recommended: dict[str, Any],
    summary: dict[str, Any],
    candidates: list[dict[str, Any]],
    history: list[dict[str, Any]],
    step_index: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return (decision, meta).

    decision = {"verdict": "proceed"|"wait", "ref": str|None, "reason": str}
    Falls back to {"verdict": "proceed"} on any error so replay never stalls.
    """
    cfg = pick_llm_config(task.get("agentProvider"))
    if not cfg:
        cfg = pick_llm_config()
    if not cfg:
        return {"verdict": "proceed"}, {"source": "no_llm"}

    client, _agent_model, provider = cfg
    model = _verifier_model(provider)
    kind = recommended.get("action") or recommended.get("type") or "click"
    intended = _recommended_target(recommended, candidates)
    valid_refs = {c.get("ref") for c in candidates if c.get("ref")}

    system = (
        "You verify ONE step of a browser automation replay. A recorded workflow "
        "(a Markov policy) already decided the next action. Your ONLY job is to "
        "look at the LIVE page and decide whether it is ready to perform that exact "
        "action right now, and which on-page element ref is the real target. "
        "Do NOT plan ahead, do NOT change the task, do NOT pick a different action. "
        "Return ONLY compact JSON."
    )
    user = (
        f"Task: {task.get('goal') or task.get('prompt') or json.dumps({k: task.get(k) for k in ('origin', 'destination', 'departDate') if task.get(k)})}\n"
        f"Step: {step_index}\n"
        f"Recorded next action: {json.dumps({'action': kind, 'value': recommended.get('value'), 'target': intended}, default=str)}\n"
        f"Current page: {json.dumps({'url': summary.get('url'), 'title': summary.get('title')}, default=str)[:600]}\n"
        f"Recent steps: {json.dumps([h.get('selectedText') or (h.get('action') or {}).get('type') for h in history[-6:]], default=str)[:600]}\n"
        f"Visible elements (ref -> text):\n{json.dumps(_compact_candidates(candidates), default=str)[:4000]}\n\n"
        "Decide:\n"
        '{"verdict":"proceed","ref":"e7","reason":"target visible"}  — element is present; ref = the element that best matches the recorded target (or null to keep the recorded ref)\n'
        '{"verdict":"wait","reason":"autocomplete not open yet"}  — the target element is NOT visible yet (page still loading, dropdown/menu not open, or a navigation is in progress)\n'
        "Rules:\n"
        "- Choose wait if the recorded target text is not represented by any visible element yet.\n"
        "- Choose proceed and set ref to the element whose text matches the recorded target.\n"
        "- Never invent a ref that is not in the list.\n"
        "- Keep reason under 8 words."
    )

    kwargs: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0,
        "max_tokens": 80,
    }
    if provider in ("openai", "openrouter"):
        kwargs["response_format"] = {"type": "json_object"}

    try:
        log_event(log, "verify_request", provider=provider, model=model, step=step_index, kind=kind)
        response = await client.chat.completions.create(**kwargs)
        raw = (response.choices[0].message.content or "").strip()
        if raw.startswith("```"):
            raw = raw.strip("`")
            if raw.lower().startswith("json"):
                raw = raw[4:]
        start, end = raw.find("{"), raw.rfind("}")
        data = json.loads(raw[start : end + 1]) if start >= 0 and end > start else {}
    except Exception as exc:  # never block replay on a verifier failure
        log_event(log, "verify_error", error=str(exc)[:160], step=step_index)
        return {"verdict": "proceed"}, {"source": "verify_error", "model": model}

    verdict = str(data.get("verdict") or "proceed").lower()
    if verdict not in ("proceed", "wait"):
        verdict = "proceed"

    ref = data.get("ref")
    if ref is not None:
        ref = str(ref).lstrip("@")
        if ref not in valid_refs:
            ref = None  # ignore hallucinated refs, keep the recorded one

    decision = {"verdict": verdict, "ref": ref, "reason": str(data.get("reason") or "")[:80]}
    meta = {"source": "verifier", "model": model, "provider": provider}
    log_event(log, "verify_decision", verdict=verdict, ref=ref, step=step_index)
    return decision, meta
