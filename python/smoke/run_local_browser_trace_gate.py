"""Collect real Google Flights traces locally with Playwright + Chrome.

This is the pragmatic trace collection path while the hosted HUD browser tunnel
is unavailable. It uses the same artifact schema as the HUD gate: DOM,
accessibility, screenshots, element crop, embeddings, model action, network
events, and a tiny trained policy.
"""

from __future__ import annotations

import asyncio
import argparse
import json
import math
import os
import time
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from openai import OpenAI
from PIL import Image
from playwright.async_api import Page, async_playwright


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = ROOT / "artifacts" / "local-browser-gate"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

TASK_MATRIX = [
    ("BOS", "LAX", "2026-07-15"),
    ("SFO", "JFK", "2026-08-12"),
    ("SEA", "DEN", "2026-09-09"),
    ("NYC", "LAX", "2026-07-22"),
    ("LAX", "CDG", "2026-10-03"),
    ("JFK", "LHR", "2026-09-18"),
    ("SFO", "NRT", "2026-11-05"),
    ("ORD", "MIA", "2026-08-28"),
    ("ATL", "SEA", "2026-07-30"),
    ("DFW", "LAS", "2026-09-12"),
    ("IAD", "SFO", "2026-10-19"),
    ("DEN", "BOS", "2026-08-05"),
    ("PHL", "PHX", "2026-11-14"),
    ("MSP", "SAN", "2026-07-19"),
    ("AUS", "JFK", "2026-09-25"),
    ("MIA", "YYZ", "2026-10-11"),
    ("EWR", "FCO", "2026-11-21"),
    ("SJC", "ORD", "2026-08-17"),
    ("PDX", "SLC", "2026-09-03"),
    ("BWI", "LAX", "2026-10-27"),
]


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def task_matrix(limit: int, offset: int) -> list[dict[str, str]]:
    tasks = [
        {"origin": origin, "destination": destination, "departDate": depart_date}
        for origin, destination, depart_date in TASK_MATRIX
    ]
    expanded: list[dict[str, str]] = []
    idx = offset
    while len(expanded) < limit:
        base = tasks[idx % len(tasks)].copy()
        base["configId"] = f"local-{idx:03d}"
        expanded.append(base)
        idx += 1
    return expanded


def parse_json_object(raw: str) -> dict[str, Any]:
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    start = raw.find("{")
    end = raw.rfind("}")
    if start != -1 and end > start:
        parsed = json.loads(raw[start : end + 1])
        if isinstance(parsed, dict):
            return parsed
    raise ValueError(f"No JSON object found in model output: {raw!r}")


def fireworks_client() -> OpenAI:
    api_key = os.getenv("FIREWORKS_API_KEY") or os.getenv("DEEPSEEK_API_KEY")
    if not api_key:
        raise RuntimeError("Missing FIREWORKS_API_KEY or DEEPSEEK_API_KEY")
    base_url = os.getenv("FIREWORKS_BASE_URL") or os.getenv("DEEPSEEK_BASE_URL") or "https://api.fireworks.ai/inference/v1"
    return OpenAI(api_key=api_key, base_url=base_url)


def openai_client() -> OpenAI:
    return OpenAI(api_key=require_env("OPENAI_API_KEY"))


def embed(client: OpenAI, text: str) -> list[float]:
    return client.embeddings.create(
        model=os.getenv("EMBEDDING_MODEL", "text-embedding-3-small"),
        input=text,
    ).data[0].embedding


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def train_tiny_policy(rows: list[dict[str, Any]]) -> dict[str, Any]:
    nodes: list[dict[str, Any]] = []
    threshold = 0.82
    for row in rows:
        emb = row["stateEmbedding"]
        node = None
        for candidate in nodes:
            if cosine(emb, candidate["centroid"]) >= threshold:
                node = candidate
                break
        if node is None:
            node = {"id": len(nodes), "urlPattern": row["url"].split("?")[0], "centroid": emb, "members": 0, "actions": []}
            nodes.append(node)
        node["members"] += 1
        node["actions"].append(
            {
                "type": row["action"]["type"],
                "ref": row["action"].get("ref"),
                "value": row["action"].get("value"),
                "elementCentroid": row.get("elementEmbedding"),
                "successRate": row.get("reward", 1.0),
                "support": 1,
            }
        )
    return {"nodes": nodes, "metadata": {"trainer": "local-browser-gate", "nodeCount": len(nodes), "traceRows": len(rows)}}


async def get_candidates(page: Page) -> list[dict[str, Any]]:
    return await page.evaluate(
        """() => [...document.querySelectorAll('input, textarea, button, [role=button], [role=option], [role=gridcell], [role=menuitem], [aria-label], a')]
          .map((el, idx) => {
            const rect = el.getBoundingClientRect();
            const text = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').trim();
            return {
              ref: `e${idx}`,
              tag: el.tagName.toLowerCase(),
              role: el.getAttribute('role') || el.tagName.toLowerCase(),
              text,
              ariaLabel: el.getAttribute('aria-label'),
              placeholder: el.getAttribute('placeholder'),
              bbox: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
              visible: rect.width > 0 && rect.height > 0,
              enabled: !el.disabled
            };
          })
          .filter(e => e.visible && e.enabled && (e.text || e.ariaLabel || e.placeholder))
          .slice(0, 500)
          .map((e, idx) => ({...e, ref: `e${idx}`}))"""
    )


async def accessibility_tree(page: Page) -> dict[str, Any]:
    session = await page.context.new_cdp_session(page)
    try:
        return await session.send("Accessibility.getFullAXTree")
    finally:
        await session.detach()


def choose_fallback_action(candidates: list[dict[str, Any]], task: dict[str, str], step_index: int) -> dict[str, Any]:
    target_text = task["origin"] if step_index == 0 else task["destination"]
    origin = next(
        (
            c
            for c in candidates
            if "from" in " ".join(str(c.get(k) or "") for k in ("text", "ariaLabel", "placeholder")).lower()
        ),
        candidates[0],
    )
    return {"action": "type", "ref": origin["ref"], "value": target_text}


async def page_summary(page: Page) -> dict[str, Any]:
    text = await page.locator("body").inner_text(timeout=5000)
    return {
        "url": page.url,
        "title": await page.title(),
        "text": text[:5000],
    }


def reached_results(summary: dict[str, Any]) -> bool:
    haystack = f"{summary.get('url', '')}\n{summary.get('title', '')}\n{summary.get('text', '')}".lower()
    return "/travel/flights/search" in haystack or (
        any(marker in haystack for marker in ("best departing flights", "departing flights"))
        and any(marker in haystack for marker in ("$", "usd", "price", "airlines", "stops"))
    )


def candidate_text(candidate: dict[str, Any]) -> str:
    return " ".join(str(candidate.get(k) or "") for k in ("text", "ariaLabel", "placeholder")).lower()


def find_candidate(candidates: list[dict[str, Any]], *needles: str) -> dict[str, Any] | None:
    lowered = [needle.lower() for needle in needles]
    matches = [candidate for candidate in candidates if all(needle in candidate_text(candidate) for needle in lowered)]
    if not matches:
        return None
    return min(
        matches,
        key=lambda candidate: (
            candidate.get("role") == "search",
            (candidate.get("bbox", {}).get("width", 9999) or 9999) * (candidate.get("bbox", {}).get("height", 9999) or 9999),
        ),
    )


def find_airport_suggestion(candidates: list[dict[str, Any]], airport_code: str) -> dict[str, Any] | None:
    code = airport_code.lower()
    matches = [
        candidate
        for candidate in candidates
        if code in candidate_text(candidate)
        and "toggle" not in candidate_text(candidate)
        and candidate.get("tag") != "input"
        and candidate.get("role") != "search"
    ]
    if not matches:
        return None
    airportish = [
        candidate
        for candidate in matches
        if any(marker in candidate_text(candidate) for marker in ("airport", "city in", "capital of", "country"))
    ]
    pool = airportish or matches
    return min(
        pool,
        key=lambda candidate: (
            (candidate.get("bbox", {}).get("width", 9999) or 9999) * (candidate.get("bbox", {}).get("height", 9999) or 9999),
            candidate.get("bbox", {}).get("y", 9999) or 9999,
        ),
    )


def find_day_candidate(candidates: list[dict[str, Any]], depart_date: str) -> dict[str, Any] | None:
    day = str(int(depart_date.split("-")[2]))
    # Google Flights shows two months. For this smoke matrix we advance until
    # the target month is in the right-hand calendar, then select by column.
    target_month = int(depart_date.split("-")[1])
    prefer_right_month = target_month >= 7
    matches = []
    for candidate in candidates:
        text = candidate_text(candidate)
        bbox = candidate.get("bbox", {})
        if candidate.get("role") == "search":
            continue
        if prefer_right_month and bbox.get("x", 0) < 720:
            continue
        if (text == day or text.startswith(f"{day} ") or text.startswith(f"{day}\n")) and bbox.get("y", 0) > 300:
            matches.append(candidate)
    if not matches:
        return None
    return min(
        matches,
        key=lambda candidate: (
            abs((candidate.get("bbox", {}).get("width", 0) or 0) - 48),
            candidate.get("bbox", {}).get("y", 9999) or 9999,
        ),
    )


def scripted_action(task: dict[str, str], candidates: list[dict[str, Any]], history: list[dict[str, Any]]) -> dict[str, Any]:
    actions = [entry["action"] for entry in history]
    typed_origin = any(action.get("type") == "type" and action.get("value") == task["origin"] for action in actions)
    typed_destination = any(action.get("type") == "type" and action.get("value") == task["destination"] for action in actions)
    clicked_departure = any("departure" in str(entry.get("selectedText") or "").lower() for entry in history)
    selected_texts = [str(entry.get("selectedText") or "").lower() for entry in history]
    trip_type_set = any("one way" in text for text in selected_texts)
    origin_selected = any(task["origin"].lower() in text and "airport" in text for text in selected_texts)
    destination_selected = any(task["destination"].lower() in text and "airport" in text for text in selected_texts)
    clicked_day = any(action.get("value") == task["departDate"] and action.get("type") == "click_date" for action in actions)
    clicked_done = any(text.strip() == "done" for text in selected_texts)
    target_month = int(task["departDate"].split("-")[1])
    next_month_clicks = sum(1 for action in actions if action.get("type") == "next_month")

    if not typed_origin and not trip_type_set:
        one_way = find_candidate(candidates, "one way")
        if one_way:
            return {"action": "click", "ref": one_way["ref"], "value": None}
        round_trip = find_candidate(candidates, "round trip")
        if round_trip:
            return {"action": "click", "ref": round_trip["ref"], "value": None}

    if not typed_origin:
        origin = find_candidate(candidates, "where from") or find_candidate(candidates, "from") or candidates[0]
        return {"action": "type", "ref": origin["ref"], "value": task["origin"]}

    if typed_origin and not typed_destination:
        origin_match = find_airport_suggestion(candidates, task["origin"])
        if not origin_selected and origin_match and origin_match.get("tag") != "input":
            return {"action": "click", "ref": origin_match["ref"], "value": None}
        destination = find_candidate(candidates, "where to") or find_candidate(candidates, "to") or candidates[0]
        return {"action": "type", "ref": destination["ref"], "value": task["destination"]}

    destination_match = find_airport_suggestion(candidates, task["destination"]) if typed_destination else None
    if not destination_selected and destination_match and destination_match.get("tag") != "input":
        return {"action": "click", "ref": destination_match["ref"], "value": None}

    if not clicked_departure:
        departure = find_candidate(candidates, "departure") or candidates[0]
        return {"action": "click", "ref": departure["ref"], "value": None}

    if not clicked_day:
        if target_month > 7 + next_month_clicks:
            next_month = find_candidate(candidates, "next") or find_candidate(candidates, "next month")
            if next_month:
                return {"action": "next_month", "ref": next_month["ref"], "value": task["departDate"]}
        day = find_day_candidate(candidates, task["departDate"])
        if day:
            return {"action": "click_date", "ref": day["ref"], "value": task["departDate"]}
        departure_input = find_candidate(candidates, "departure") or candidates[0]
        return {"action": "type", "ref": departure_input["ref"], "value": task["departDate"]}

    if not clicked_done:
        done = find_candidate(candidates, "done")
        if done:
            return {"action": "click", "ref": done["ref"], "value": None}
        return {"action": "click_xy", "ref": None, "value": "Done", "x": 1078, "y": 770}

    search = find_candidate(candidates, "search") or find_candidate(candidates, "explore") or candidates[-1]
    return {"action": "click", "ref": search["ref"], "value": None}


def ask_action(
    client: OpenAI,
    task: dict[str, str],
    summary: dict[str, Any],
    candidates: list[dict[str, Any]],
    history: list[dict[str, Any]],
    step_index: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    model = os.getenv("FIREWORKS_MODEL", "accounts/fireworks/models/deepseek-v4-pro")
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": "You are a browser agent. Return only valid compact JSON. No markdown. No explanation."},
            {
                "role": "user",
                "content": (
                    "Complete this Google Flights task end-to-end: enter origin, destination, departure date, "
                    "submit the search, and stop only once flight results are visible. "
                    "Choose exactly one next action. Allowed JSON shapes: "
                    "{\"action\":\"click\",\"ref\":\"candidate ref\",\"value\":null}, "
                    "{\"action\":\"type\",\"ref\":\"candidate ref\",\"value\":\"text\"}, "
                    "{\"action\":\"press\",\"ref\":null,\"value\":\"Enter|Escape|Tab|ArrowDown\"}, "
                    "{\"action\":\"done\",\"ref\":null,\"value\":null}. "
                    "Use airport codes as typed values. If an autocomplete list is open, press Enter or click the matching option. "
                    f"Task: {json.dumps(task)} Step: {step_index} "
                    f"Current page summary: {json.dumps(summary)} "
                    f"Recent actions: {json.dumps(history[-6:])} "
                    f"Candidate elements: {json.dumps(candidates[:45])}"
                ),
            },
        ],
        temperature=0,
        max_tokens=512,
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or ""
    return parse_json_object(raw), {"model": model, "raw": raw, "usage": response.usage.model_dump() if response.usage else {}}


def validate_action(action: dict[str, Any], candidates: list[dict[str, Any]]) -> None:
    refs = {candidate["ref"] for candidate in candidates}
    if action.get("action") not in {"click", "click_date", "next_month", "click_xy", "type", "press", "done"}:
        raise ValueError(f"Invalid action type: {action.get('action')!r}")
    if action.get("action") in {"press", "done"}:
        return
    if action.get("action") == "click_xy":
        if not isinstance(action.get("x"), (int, float)) or not isinstance(action.get("y"), (int, float)):
            raise ValueError("click_xy requires numeric x/y")
        return
    if action.get("ref") not in refs:
        raise ValueError(f"Invalid action ref: {action.get('ref')!r}")
    if action.get("action") == "type" and not isinstance(action.get("value"), str):
        raise ValueError("Type action requires string value")


async def click_or_type(page: Page, candidates: list[dict[str, Any]], action: dict[str, Any]) -> dict[str, Any]:
    if action.get("action") == "press":
        await page.keyboard.press(str(action.get("value") or "Enter"))
        await page.wait_for_timeout(1800)
        return {
            "ref": None,
            "role": "keyboard",
            "text": str(action.get("value") or "Enter"),
            "bbox": {"x": 0, "y": 0, "width": 1, "height": 1},
        }
    if action.get("action") == "click_xy":
        x = float(action["x"])
        y = float(action["y"])
        await page.mouse.click(x, y)
        await page.wait_for_timeout(1500)
        return {
            "ref": None,
            "role": "coordinate",
            "text": str(action.get("value") or "coordinate click"),
            "bbox": {"x": x - 1, "y": y - 1, "width": 2, "height": 2},
        }
    selected = next((c for c in candidates if c["ref"] == action.get("ref")), candidates[0])
    bbox = selected["bbox"]
    x = bbox["x"] + bbox["width"] / 2
    y = bbox["y"] + bbox["height"] / 2
    if action.get("action") == "type":
        await page.mouse.click(x, y)
        await page.keyboard.press("Meta+A")
        await page.keyboard.type(str(action.get("value") or ""), delay=20)
    else:
        await page.mouse.click(x, y)
    await page.wait_for_timeout(1500)
    return selected


def crop_element(full_page: Path, out_path: Path, bbox: dict[str, Any]) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(full_page) as image:
        x = max(0, int(bbox["x"]))
        y = max(0, int(bbox["y"]))
        w = max(1, int(bbox["width"]))
        h = max(1, int(bbox["height"]))
        image.crop((x, y, x + w, y + h)).save(out_path)


async def capture_step(
    page: Page,
    trace_dir: Path,
    step_index: int,
    task: dict[str, str],
    candidates: list[dict[str, Any]],
    selected: dict[str, Any],
    action: dict[str, Any],
    model_meta: dict[str, Any],
    state_summary: dict[str, Any],
    next_summary: dict[str, Any],
    next_candidates: list[dict[str, Any]],
    openai: OpenAI,
) -> dict[str, Any]:
    screenshot_full = trace_dir / "screenshots" / f"step_{step_index:03d}_fullpage.png"
    screenshot_viewport = trace_dir / "screenshots" / f"step_{step_index:03d}_viewport.png"
    element_path = trace_dir / "screenshots" / f"step_{step_index:03d}_element.png"
    await page.screenshot(path=screenshot_viewport, full_page=False)
    await page.screenshot(path=screenshot_full, full_page=True)
    crop_element(screenshot_full, element_path, selected["bbox"])

    ax = await accessibility_tree(page)
    html = await page.content()
    state_text = json.dumps({"summary": state_summary, "elements": candidates[:45]}, sort_keys=True)
    next_state_text = json.dumps({"summary": next_summary, "elements": next_candidates[:45]}, sort_keys=True)
    row = {
        "stepIndex": step_index,
        "timestamp": int(time.time() * 1000),
        "task": task,
        "url": state_summary["url"],
        "title": state_summary["title"],
        "stateText": state_text,
        "stateEmbedding": embed(openai, state_text),
        "action": {
            "type": action.get("action"),
            "ref": action.get("ref"),
            "value": action.get("value"),
            "x": action.get("x"),
            "y": action.get("y"),
        },
        "selectedElement": selected,
        "elementEmbedding": embed(openai, json.dumps(selected, sort_keys=True)),
        "nextStateText": next_state_text,
        "nextStateEmbedding": embed(openai, next_state_text),
        "reward": 1.0 if reached_results(next_summary) or action.get("action") == "done" else 0.0,
        "artifacts": {
            "viewportScreenshot": f"screenshots/step_{step_index:03d}_viewport.png",
            "fullPageScreenshot": f"screenshots/step_{step_index:03d}_fullpage.png",
            "elementScreenshot": f"screenshots/step_{step_index:03d}_element.png",
            "accessibility": f"accessibility/step_{step_index:03d}.json",
            "dom": f"dom/step_{step_index:03d}.html",
        },
        "model": model_meta,
    }
    write_json(trace_dir / "accessibility" / f"step_{step_index:03d}.json", ax)
    (trace_dir / "dom").mkdir(parents=True, exist_ok=True)
    (trace_dir / "dom" / f"step_{step_index:03d}.html").write_text(html)
    return row


async def collect_one(
    browser: Any,
    out: Path,
    idx: int,
    task: dict[str, str],
    fireworks: OpenAI,
    openai: OpenAI,
    max_steps: int,
    expert: str,
) -> dict[str, Any]:
    trace_dir = out / f"trace_{idx:03d}_{task['origin']}_{task['destination']}"
    trace_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict[str, Any]] = []
    context = await browser.new_context(viewport={"width": 1280, "height": 800}, device_scale_factor=1)
    page = await context.new_page()
    page.on("request", lambda req: events.append({"type": "request", "url": req.url, "method": req.method, "timestamp": time.time()}))
    page.on("response", lambda res: events.append({"type": "response", "url": res.url, "status": res.status, "timestamp": time.time()}))
    try:
        await page.goto("https://www.google.com/travel/flights", wait_until="domcontentloaded", timeout=60000)
        await page.wait_for_timeout(6000)
        rows: list[dict[str, Any]] = []
        history: list[dict[str, Any]] = []
        terminal_reason = "max_steps"
        for step_index in range(max_steps):
            candidates = await get_candidates(page)
            state_summary = await page_summary(page)
            if step_index > 0 and reached_results(state_summary):
                terminal_reason = "results_detected"
                break
            try:
                if expert == "scripted":
                    action = scripted_action(task, candidates, history)
                    model_meta = {"model": "scripted-google-flights-expert", "raw": json.dumps(action), "usage": {}}
                else:
                    action, model_meta = ask_action(fireworks, task, state_summary, candidates, history, step_index)
                validate_action(action, candidates)
            except Exception as exc:
                action = choose_fallback_action(candidates, task, step_index)
                model_meta = {"model": "fallback-local-rule", "raw": "", "error": f"{type(exc).__name__}: {exc}", "usage": {}}
            if action.get("action") == "done":
                terminal_reason = "expert_done"
                break
            selected = await click_or_type(page, candidates, action)
            next_summary = await page_summary(page)
            next_candidates = await get_candidates(page)
            row = await capture_step(
                page,
                trace_dir,
                step_index,
                task,
                candidates,
                selected,
                action,
                model_meta,
                state_summary,
                next_summary,
                next_candidates,
                openai,
            )
            rows.append(row)
            history.append({"step": step_index, "action": row["action"], "selectedText": selected.get("text"), "url": next_summary["url"]})
            if reached_results(next_summary):
                terminal_reason = "results_detected"
                break

        write_jsonl(trace_dir / "network" / "events.jsonl", events[-200:])
        write_jsonl(trace_dir / "trace.jsonl", rows)
        write_json(trace_dir / "metadata.json", {"task": task, "url": page.url, "steps": len(rows), "terminalReason": terminal_reason})
        ok = terminal_reason == "results_detected" and len(rows) > 0
        return {
            "ok": ok,
            "task": task,
            "steps": len(rows),
            "terminalReason": terminal_reason,
            "finalAction": rows[-1]["action"] if rows else None,
            "url": page.url,
            "dir": str(trace_dir.relative_to(ROOT)),
            "rows": rows,
        }
    except Exception as exc:
        write_json(trace_dir / "error.json", {"task": task, "error": f"{type(exc).__name__}: {exc}"})
        return {"ok": False, "task": task, "error": f"{type(exc).__name__}: {exc}", "dir": str(trace_dir.relative_to(ROOT))}
    finally:
        await context.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect local Google Flights trace artifacts.")
    parser.add_argument("--limit", type=int, default=3, help="Number of traces to attempt.")
    parser.add_argument("--offset", type=int, default=0, help="Offset into the deterministic task matrix.")
    parser.add_argument("--out", type=Path, default=None, help="Output directory. Defaults to artifacts/local-browser-gate/gate_<timestamp>.")
    parser.add_argument("--headed", action="store_true", help="Run Chrome headed for manual inspection.")
    parser.add_argument("--max-steps", type=int, default=10, help="Maximum browser actions per trace.")
    parser.add_argument("--expert", choices=("scripted", "llm"), default="scripted", help="Action source for trace collection.")
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    load_dotenv(ROOT / ".env")
    run_id = f"gate_{time.strftime('%Y%m%d_%H%M%S')}"
    out = args.out if args.out is not None else ARTIFACT_ROOT / run_id
    if not out.is_absolute():
        out = ROOT / out
    out.mkdir(parents=True, exist_ok=True)
    tasks = task_matrix(args.limit, args.offset)
    fireworks = fireworks_client()
    openai_client_instance = openai_client()
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            executable_path=CHROME,
            headless=not args.headed,
            args=["--disable-blink-features=AutomationControlled"],
        )
        try:
            results = []
            for idx, task in enumerate(tasks):
                results.append(await collect_one(browser, out, idx, task, fireworks, openai_client_instance, args.max_steps, args.expert))
        finally:
            await browser.close()

    rows = [row for result in results for row in result.get("rows", [])]
    policy = train_tiny_policy(rows)
    write_jsonl(out / "all_traces.jsonl", rows)
    write_json(out / "policy.json", policy)
    report = {
        "ok": sum(1 for result in results if result.get("ok")) == len(tasks),
        "runDir": str(out.relative_to(ROOT)),
        "attempted": len(tasks),
        "succeeded": sum(1 for result in results if result.get("ok")),
        "failed": sum(1 for result in results if not result.get("ok")),
        "stepRows": len(rows),
        "runs": [{k: v for k, v in result.items() if k != "rows"} for result in results],
        "policy": policy["metadata"],
    }
    write_json(out / "report.json", report)
    print(json.dumps(report, indent=2))
    if not report["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
