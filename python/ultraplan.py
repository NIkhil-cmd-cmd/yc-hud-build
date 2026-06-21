"""Ultraplan goal decomposition and subtask execution orchestration."""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from agent_loop import AgentTaskSession
from agent_llm import pick_llm_config
from executor import PolicyExecutor
from log_config import log_event, setup_logging

log = setup_logging("openhive.ultraplan")
SendFn = Callable[[dict[str, Any]], Awaitable[None]]

MAX_PLANNER_CHARS = 40_000
IRREVERSIBLE_RE = re.compile(
    r"\b(book now|reserve|confirm|purchase|pay|payment|checkout|place order|submit order)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class WorkflowMatch:
    workflow: dict[str, Any]
    score: float
    reason: str


@dataclass(frozen=True)
class WorkflowRelevance:
    applicable: bool
    params: dict[str, str]
    reason: str


def parse_planner_json(text: str, *, max_chars: int = MAX_PLANNER_CHARS) -> dict[str, Any]:
    """Parse and validate strict ultraplan JSON."""
    if not text or not text.strip():
        raise ValueError("Planner returned empty output")
    if len(text) > max_chars:
        raise ValueError("Planner output is too large")

    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)

    data = json.loads(cleaned)
    if not isinstance(data, dict):
        raise ValueError("Planner JSON must be an object")
    if not isinstance(data.get("summary"), str) or not data["summary"].strip():
        raise ValueError("Planner JSON requires a non-empty summary")
    subtasks = data.get("subtasks")
    if not isinstance(subtasks, list) or not subtasks:
        raise ValueError("Planner JSON requires at least one subtask")

    normalized: list[dict[str, Any]] = []
    for idx, raw in enumerate(subtasks[:16], start=1):
        if not isinstance(raw, dict):
            raise ValueError("Each subtask must be an object")
        goal = str(raw.get("goal") or "").strip()
        title = str(raw.get("title") or goal or f"Subtask {idx}").strip()
        if not goal:
            raise ValueError(f"Subtask {idx} requires a goal")
        required = raw.get("requiredInputs") or []
        if not isinstance(required, list):
            raise ValueError(f"Subtask {idx} requiredInputs must be a list")
        normalized.append(
            {
                "id": str(raw.get("id") or f"subtask_{idx}"),
                "title": title,
                "goal": goal,
                "domain": str(raw.get("domain") or "").strip(),
                "requiredInputs": [str(v) for v in required if str(v).strip()],
                "safety": str(raw.get("safety") or "stop_before_purchase"),
            }
        )

    return {"summary": data["summary"].strip(), "subtasks": normalized}


def heuristic_plan(goal: str) -> dict[str, Any]:
    """Deterministic fallback when no planner LLM is configured."""
    lower = goal.lower()
    subtasks: list[dict[str, Any]] = []
    if any(word in lower for word in ("flight", "trip", "travel", "italy")):
        subtasks.append(
            {
                "id": "subtask_1",
                "title": "Find flights",
                "goal": f"Find flight options for: {goal}. Stop when results/options are visible.",
                "domain": "travel.flights",
                "requiredInputs": ["origin", "destination", "dates", "travelers"],
                "safety": "stop_before_purchase",
            }
        )
    if any(word in lower for word in ("hotel", "trip", "travel", "stay", "italy")):
        subtasks.append(
            {
                "id": f"subtask_{len(subtasks) + 1}",
                "title": "Find hotels",
                "goal": f"Find hotel options for: {goal}. Stop before reservation confirmation.",
                "domain": "travel.hotels",
                "requiredInputs": ["destination", "dates", "travelers"],
                "safety": "stop_before_purchase",
            }
        )
    if any(word in lower for word in ("attraction", "activities", "trip", "travel", "italy")):
        subtasks.append(
            {
                "id": f"subtask_{len(subtasks) + 1}",
                "title": "Find attractions",
                "goal": f"Find attractions and activities for: {goal}.",
                "domain": "travel.attractions",
                "requiredInputs": ["destination"],
                "safety": "stop_before_purchase",
            }
        )
    if any(word in lower for word in ("cost", "budget", "estimate", "trip", "travel")):
        subtasks.append(
            {
                "id": f"subtask_{len(subtasks) + 1}",
                "title": "Estimate costs",
                "goal": f"Estimate costs for: {goal}.",
                "domain": "travel.costs",
                "requiredInputs": ["destination", "dates", "travelers"],
                "safety": "read_only",
            }
        )
    if not subtasks:
        subtasks.append(
            {
                "id": "subtask_1",
                "title": "Complete goal",
                "goal": goal,
                "domain": "general.browser",
                "requiredInputs": [],
                "safety": "stop_before_purchase",
            }
        )
    return {"summary": goal[:120], "subtasks": subtasks[:8]}


async def decompose_goal(goal: str, context: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return an UltraPlan dict, using OPENHIVE_ULTRAPLAN_MODEL when possible."""
    cfg = pick_llm_config()
    if not cfg:
        return heuristic_plan(goal)

    client, default_model, provider = cfg
    model = os.getenv("OPENHIVE_ULTRAPLAN_MODEL") or default_model
    prompt = {
        "goal": goal,
        "context": context or {},
        "rules": [
            "Return only strict JSON.",
            "Decompose into executable browser subtasks.",
            "Use stop_before_purchase for booking, payment, login, reservation, or checkout flows.",
            "List requiredInputs that cannot be safely guessed.",
            "Use compact domain labels such as travel.flights, travel.hotels, travel.attractions, travel.costs.",
        ],
        "schema": {
            "summary": "short summary",
            "subtasks": [
                {
                    "id": "subtask_1",
                    "title": "Find flights",
                    "goal": "Find flight options",
                    "domain": "travel.flights",
                    "requiredInputs": ["origin", "dates", "travelers"],
                    "safety": "stop_before_purchase",
                }
            ],
        },
    }
    kwargs: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are an automation planner. Return only valid JSON."},
            {"role": "user", "content": json.dumps(prompt)},
        ],
        "temperature": 0,
        "max_tokens": 1400,
    }
    if provider in ("openai", "openrouter"):
        kwargs["response_format"] = {"type": "json_object"}
    response = await client.chat.completions.create(**kwargs)
    return parse_planner_json(response.choices[0].message.content or "")


def _tokens(*values: str) -> set[str]:
    joined = " ".join(v for v in values if v)
    return {t for t in re.findall(r"[a-z0-9]+", joined.lower()) if len(t) > 2}


def match_subtask_to_workflow(subtask: dict[str, Any], workflows: list[dict[str, Any]]) -> WorkflowMatch | None:
    """Conservatively match a subtask to a trained workflow."""
    sub_domain = str(subtask.get("domain") or "").lower()
    sub_tokens = _tokens(subtask.get("title", ""), subtask.get("goal", ""), sub_domain)
    best: WorkflowMatch | None = None

    for wf in workflows:
        meta = wf.get("metadata") if isinstance(wf.get("metadata"), dict) else {}
        domains = [str(d).lower() for d in meta.get("domains", []) if str(d).strip()]
        capabilities = [str(c).lower() for c in meta.get("capabilities", []) if str(c).strip()]
        name = str(wf.get("name") or wf.get("id") or "")
        wf_tokens = _tokens(name, " ".join(domains), " ".join(capabilities))

        score = 0.0
        reason = "name"
        if sub_domain and sub_domain in domains:
            score += 0.75
            reason = "metadata_domain"
        elif sub_domain and any(sub_domain.split(".")[-1] in d for d in domains):
            score += 0.45
            reason = "metadata_domain_keyword"

        if sub_tokens and wf_tokens:
            overlap = len(sub_tokens & wf_tokens) / max(1, len(sub_tokens))
            score += min(0.35, overlap)

        if capabilities and any(c in sub_tokens or c.replace("_", "") in sub_tokens for c in capabilities):
            score += 0.2
            reason = "metadata_capability"

        threshold = 0.62 if meta else 0.34
        if score >= threshold and (best is None or score > best.score):
            best = WorkflowMatch(workflow=wf, score=score, reason=reason)

    return best


def missing_required_inputs(subtask: dict[str, Any], goal: str, context: dict[str, Any] | None = None) -> list[str]:
    """Return required inputs that are not present in user/context text."""
    required = [str(v).strip() for v in subtask.get("requiredInputs") or [] if str(v).strip()]
    if not required:
        return []
    haystack = " ".join(
        [
            goal,
            subtask.get("goal", ""),
            json.dumps(context or {}, default=str),
        ]
    ).lower()
    missing: list[str] = []
    aliases = {
        "origin": [r"\bfrom\b", r"\borigin\b", r"\b[A-Z]{3}\b"],
        "dates": [r"\bdate", r"\bjan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec\b", r"\b\d{4}-\d{2}-\d{2}\b"],
        "travelers": [r"\btraveler", r"\bpassenger", r"\badult", r"\b\d+\s+(people|person|travelers|passengers)\b"],
        "destination": [r"\bto\b", r"\bdestination\b", r"\bitaly\b", r"\brome\b", r"\bflorence\b", r"\bvenice\b"],
    }
    for item in required:
        pats = aliases.get(item.lower(), [re.escape(item.lower())])
        if not any(re.search(p, haystack, re.IGNORECASE) for p in pats):
            missing.append(item)
    return missing


def workflow_relevance_for_subtask(
    subtask: dict[str, Any],
    workflow: dict[str, Any],
    root_goal: str,
) -> WorkflowRelevance:
    """Validate a matched workflow against the concrete subtask before replay."""
    params = extract_workflow_params(subtask, root_goal, workflow)
    schema = workflow_input_schema(workflow, subtask)
    missing = [field for field in schema if field not in params]
    if missing:
        return WorkflowRelevance(False, params, f"missing workflow inputs: {', '.join(missing)}")

    conflict = first_literal_conflict(workflow, params, f"{root_goal} {subtask.get('goal', '')}")
    if conflict:
        return WorkflowRelevance(False, params, conflict)

    return WorkflowRelevance(True, params, "matched")


def workflow_input_schema(workflow: dict[str, Any], subtask: dict[str, Any]) -> list[str]:
    meta = workflow.get("metadata") if isinstance(workflow.get("metadata"), dict) else {}
    raw_schema = meta.get("inputSchema") or meta.get("inputs") or []
    schema = [canonical_input_name(str(v)) for v in raw_schema if str(v).strip()]
    schema = [v for v in schema if v]
    if schema:
        return _dedupe(schema)
    if str(subtask.get("domain") or "").lower() == "travel.flights":
        return ["origin", "destination", "departDate"]
    return []


def canonical_input_name(name: str) -> str:
    key = re.sub(r"[^a-z0-9]", "", name.lower())
    aliases = {
        "from": "origin",
        "origin": "origin",
        "departureairport": "origin",
        "to": "destination",
        "dest": "destination",
        "destination": "destination",
        "arrivalairport": "destination",
        "date": "departDate",
        "dates": "departDate",
        "departdate": "departDate",
        "departuredate": "departDate",
        "traveler": "travelers",
        "travelers": "travelers",
        "passengers": "travelers",
    }
    return aliases.get(key, name)


def extract_workflow_params(
    subtask: dict[str, Any],
    root_goal: str = "",
    workflow: dict[str, Any] | None = None,
) -> dict[str, str]:
    text = f"{root_goal} {subtask.get('title', '')} {subtask.get('goal', '')}"
    params = _extract_explicit_params(text)

    if "origin" not in params:
        origin = _extract_place_after(text, ("from", "leaving from", "departing from", "origin"))
        if origin:
            params["origin"] = _normalize_place(origin)
    if "destination" not in params:
        destination = _extract_place_after(text, ("to", "for", "destination"))
        normalized = _normalize_place(destination) if destination else ""
        if normalized and normalized.lower() not in {"italy", "europe"}:
            params["destination"] = normalized

    if "departDate" not in params:
        date = _extract_date(text)
        if date:
            params["departDate"] = date
    if "travelers" not in params:
        travelers = _extract_travelers(text)
        if travelers:
            params["travelers"] = travelers

    schema = workflow_input_schema(workflow or {}, subtask)
    return {k: v for k, v in params.items() if not schema or k in schema or k == "travelers"}


def _extract_explicit_params(text: str) -> dict[str, str]:
    params: dict[str, str] = {}
    for key in ("origin", "destination", "departDate", "depart_date", "travelers"):
        m = re.search(rf"\b{key}\s*[:=]\s*([A-Za-z0-9 /,-]+)", text, re.IGNORECASE)
        if m:
            params[canonical_input_name(key)] = m.group(1).strip(" .,")
    return params


def _extract_place_after(text: str, markers: tuple[str, ...]) -> str:
    stop = r"(?=\s+(?:to|on|departing|leaving|returning|for\s+\d|with|and|then)|[,\.]|$)"
    for marker in markers:
        pattern = rf"\b{re.escape(marker)}\s+([A-Za-z][A-Za-z .'-]*?){stop}"
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            return m.group(1).strip(" .,")
    return ""


def _normalize_place(place: str) -> str:
    raw = place.strip(" .,")
    lower = raw.lower()
    aliases = {
        "la": "Los Angeles",
        "lax": "LAX",
        "sf": "San Francisco",
        "sfo": "SFO",
        "nyc": "NYC",
        "rome": "Rome",
        "rom": "Rome",
        "milan": "Milan",
        "venice": "Venice",
        "florence": "Florence",
        "italy": "Italy",
    }
    if re.fullmatch(r"[A-Za-z]{3}", raw):
        return raw.upper()
    return aliases.get(lower, raw)


def _extract_date(text: str) -> str:
    iso = re.search(r"\b\d{4}-\d{2}-\d{2}\b", text)
    if iso:
        return iso.group(0)
    month = re.search(
        r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:,\s*\d{4})?",
        text,
        re.IGNORECASE,
    )
    if month:
        return month.group(0)
    return ""


def _extract_travelers(text: str) -> str:
    m = re.search(r"\b(\d+)\s+(?:traveler|travelers|passenger|passengers|adult|adults|people|person)\b", text, re.IGNORECASE)
    return m.group(1) if m else ""


def first_literal_conflict(workflow: dict[str, Any], params: dict[str, str], task_text: str) -> str | None:
    """Catch replay actions that would type/navigate toward a different concrete task."""
    expected = _geo_tokens(" ".join([task_text, *params.values()]))
    if not expected:
        return None
    for action in _workflow_actions(workflow):
        if (action.get("type") or "").lower() not in {"type", "fill", "navigate"}:
            continue
        literal = " ".join(str(action.get(k) or "") for k in ("value", "text", "name", "url"))
        if "{" in literal and "}" in literal:
            continue
        actual = _geo_tokens(literal)
        conflict = actual - expected
        if conflict:
            return f"workflow literal conflicts with task: {', '.join(sorted(conflict))}"
    return None


def _workflow_actions(workflow: dict[str, Any]) -> list[dict[str, Any]]:
    actions = workflow.get("actions")
    if isinstance(actions, list):
        return [a for a in actions if isinstance(a, dict)]
    policy = workflow.get("policy")
    if isinstance(policy, dict):
        out = []
        for entry in policy.values():
            if isinstance(entry, dict) and isinstance(entry.get("action"), dict):
                out.append(entry["action"])
        return out
    return []


def _geo_tokens(text: str) -> set[str]:
    lower = text.lower()
    known = {
        "lax": "los_angeles",
        "los angeles": "los_angeles",
        "la": "los_angeles",
        "sfo": "san_francisco",
        "san francisco": "san_francisco",
        "nyc": "new_york",
        "new york": "new_york",
        "jfk": "new_york",
        "rome": "rome",
        "fco": "rome",
        "milan": "milan",
        "mxp": "milan",
        "venice": "venice",
        "vce": "venice",
        "florence": "florence",
        "flr": "florence",
        "italy": "italy",
    }
    found: set[str] = set()
    for needle, canonical in known.items():
        if re.search(rf"(?<![a-z0-9]){re.escape(needle)}(?![a-z0-9])", lower):
            found.add(canonical)
    return found


def _dedupe(values: list[str]) -> list[str]:
    out = []
    for value in values:
        if value not in out:
            out.append(value)
    return out


def _action_is_irreversible(action: dict[str, Any]) -> bool:
    return bool(IRREVERSIBLE_RE.search(json.dumps(action, default=str)))


class UltraPlanSession(AgentTaskSession):
    async def run_workflow_subtask(
        self,
        subtask: dict[str, Any],
        workflow: dict[str, Any],
        *,
        max_steps: int,
        params: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        self._running = True
        executor = PolicyExecutor(workflow, params or extract_workflow_params(subtask, workflow=workflow))
        try:
            try:
                state = await self._wait_state(timeout=6)
            except asyncio.TimeoutError:
                state = {"url": "", "title": "", "accessibilityTree": None}
            for step in range(max_steps):
                result = await executor.next_action(
                    state.get("url", ""),
                    state.get("title", ""),
                    state.get("accessibilityTree"),
                )
                if result.get("done") or not result.get("action"):
                    return {"success": True, "steps": step, "reason": result.get("reason", "done")}
                action = result["action"]
                if subtask.get("safety") == "stop_before_purchase" and _action_is_irreversible(action):
                    await self._send(
                        {
                            "type": "ultraplan_safety_stop",
                            "subtaskId": subtask.get("id"),
                            "message": "Stopped before purchase, payment, or reservation confirmation.",
                        }
                    )
                    return {"success": True, "steps": step, "reason": "safety_stop"}
                await self._send(
                    {
                        "type": "execute_action",
                        "backend": "webkit",
                        "action": action,
                        "step": step + 1,
                        "total": max_steps,
                        "tier": result.get("tier", 1),
                        "mode": "ultraplan_workflow",
                    }
                )
                await asyncio.sleep(0.8)
                state = await self._wait_state(timeout=30)
            return {"success": False, "steps": max_steps, "reason": "max_steps"}
        finally:
            self._running = False


async def _run_agent_subtask(
    send: SendFn,
    subtask: dict[str, Any],
    *,
    storage_state: dict[str, Any] | None,
    page_url: str | None,
    page_title: str | None,
    max_steps: int,
    session: UltraPlanSession | None = None,
) -> dict[str, Any]:
    async def filtered_send(payload: dict[str, Any]) -> None:
        if payload.get("type") in {"execute_done", "trajectory_complete"}:
            return
        await send(payload)

    from browser_use_runner import browser_use_enabled, run_browser_use_task

    goal = subtask["goal"]
    if browser_use_enabled():
        return await run_browser_use_task(
            filtered_send,
            goal,
            page_url=page_url,
            page_title=page_title,
            storage_state=storage_state,
            max_steps=max_steps,
        )
    runner = session or AgentTaskSession(filtered_send)
    old_send = runner._send
    runner._send = filtered_send
    try:
        return await runner.run({"goal": goal}, max_steps=max_steps, start_url=page_url)
    finally:
        runner._send = old_send


async def run_ultraplan(
    send: SendFn,
    goal: str,
    *,
    workflows: list[dict[str, Any]],
    storage_state: dict[str, Any] | None = None,
    page_url: str | None = None,
    page_title: str | None = None,
    max_subtasks: int = 8,
    max_steps_per_subtask: int = 40,
    safety: dict[str, Any] | None = None,
    session: UltraPlanSession | None = None,
) -> dict[str, Any]:
    t0 = time.time()
    context = {"pageUrl": page_url or "", "pageTitle": page_title or ""}
    plan = await decompose_goal(goal, context)
    subtasks = plan["subtasks"][:max_subtasks]
    stop_before_purchase = (safety or {}).get("stopBeforePurchase", True)
    if stop_before_purchase:
        for st in subtasks:
            if st.get("safety") not in {"read_only", "safe"}:
                st["safety"] = "stop_before_purchase"

    await send({"type": "ultraplan_started", "summary": plan["summary"], "subtasks": subtasks})
    await send({"type": "execute_started", "backend": "webkit", "workflowName": plan["summary"][:80], "agentMode": "ultraplan"})

    results: list[dict[str, Any]] = []
    for idx, subtask in enumerate(subtasks, start=1):
        missing = missing_required_inputs(subtask, goal, context)
        if missing:
            question = f"Need {', '.join(missing)} for {subtask['title']}."
            await send({"type": "ultraplan_input_required", "subtask": subtask, "question": question})
            results.append({"subtaskId": subtask["id"], "success": False, "reason": "missing_inputs", "missing": missing})
            break

        match = match_subtask_to_workflow(subtask, workflows)
        await send(
            {
                "type": "ultraplan_subtask_started",
                "subtask": subtask,
                "index": idx,
                "total": len(subtasks),
                "workflowId": match.workflow.get("id") if match else None,
                "workflowName": match.workflow.get("name") if match else None,
                "matchScore": match.score if match else None,
            }
        )
        log_event(log, "subtask_start", subtask=subtask.get("title"), matched=bool(match))

        if match:
            relevance = workflow_relevance_for_subtask(subtask, match.workflow, goal)
            if not relevance.applicable:
                await send(
                    {
                        "type": "ultraplan_workflow_skipped",
                        "subtask": subtask,
                        "workflowId": match.workflow.get("id"),
                        "workflowName": match.workflow.get("name"),
                        "reason": relevance.reason,
                    }
                )
                match = None
            else:
                await send(
                    {
                        "type": "ultraplan_workflow_selected",
                        "subtask": subtask,
                        "workflowId": match.workflow.get("id"),
                        "workflowName": match.workflow.get("name"),
                        "params": relevance.params,
                    }
                )

        if match:
            runner = session or UltraPlanSession(send)
            result = await runner.run_workflow_subtask(
                subtask,
                match.workflow,
                max_steps=max_steps_per_subtask,
                params=relevance.params,
            )
        else:
            result = await _run_agent_subtask(
                send,
                subtask,
                storage_state=storage_state,
                page_url=page_url,
                page_title=page_title,
                max_steps=max_steps_per_subtask,
                session=session,
            )

        item = {"subtaskId": subtask["id"], "title": subtask["title"], **result}
        results.append(item)
        await send({"type": "ultraplan_subtask_done", "subtask": subtask, "result": item})
        if result.get("reason") in {"safety_stop", "missing_inputs"}:
            break

    success = all(r.get("success") for r in results) if results else False
    final = {
        "success": success,
        "summary": plan["summary"],
        "results": results,
        "elapsedSec": round(time.time() - t0, 1),
    }
    await send({"type": "ultraplan_done", **final})
    await send({"type": "execute_done", "hudStatus": "ok" if success else "partial"})
    return final
