"""Collect three real HUD browser traces through CDP and train a tiny policy.

This is the first real-browser gate after the synthetic provider smoke. It uses
HUD's hosted browser environment, attaches locally to the run's CDP capability,
captures multimodal artifacts, asks Fireworks for one structured action, executes
that action, embeds the state, and trains a small policy file.
"""

from __future__ import annotations

import asyncio
import base64
import json
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from hud.agents.base import Agent
from hud.eval import Task, Taskset
from openai import OpenAI
from PIL import Image
from playwright.async_api import Page, async_playwright


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = ROOT / "artifacts" / "hud-browser-gate"


TASKS = [
    {"origin": "BOS", "destination": "LAX", "departDate": "2026-07-15"},
    {"origin": "SFO", "destination": "JFK", "departDate": "2026-08-12"},
    {"origin": "SEA", "destination": "DEN", "departDate": "2026-09-09"},
]

TRACE_COUNT = int(os.getenv("TRACE_COUNT", "3"))


@dataclass
class ProviderMeta:
    model: str
    raw: str
    usage: dict[str, Any]


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

    def node_for(row: dict[str, Any]) -> int:
        emb = row["stateEmbedding"]
        url_key = row["url"].split("?")[0]
        for node in nodes:
            if node["urlPattern"] == url_key and cosine(emb, node["centroid"]) >= threshold:
                members = node["members"] + 1
                node["centroid"] = [
                    (old * node["members"] + new) / members
                    for old, new in zip(node["centroid"], emb, strict=True)
                ]
                node["members"] = members
                return int(node["id"])
        node_id = len(nodes)
        nodes.append({"id": node_id, "urlPattern": url_key, "centroid": emb, "members": 1, "actions": []})
        return node_id

    for row in rows:
        node = nodes[node_for(row)]
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
    return {"nodes": nodes, "metadata": {"trainer": "hud-browser-gate", "nodeCount": len(nodes), "traceRows": len(rows)}}


async def get_candidates(page: Page) -> list[dict[str, Any]]:
    return await page.evaluate(
        """() => {
          const nodes = [...document.querySelectorAll('input, textarea, button, [role=button], [aria-label], a')];
          return nodes.slice(0, 80).map((el, idx) => {
            const rect = el.getBoundingClientRect();
            const text = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').trim();
            return {
              ref: `e${idx}`,
              tag: el.tagName.toLowerCase(),
              role: el.getAttribute('role') || el.tagName.toLowerCase(),
              text,
              ariaLabel: el.getAttribute('aria-label'),
              placeholder: el.getAttribute('placeholder'),
              selector: el.id ? `#${CSS.escape(el.id)}` : null,
              bbox: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
              visible: rect.width > 0 && rect.height > 0,
              enabled: !el.disabled
            };
          }).filter(e => e.visible && e.enabled && (e.text || e.ariaLabel || e.placeholder));
        }"""
    )


async def click_or_type(page: Page, candidates: list[dict[str, Any]], action: dict[str, Any]) -> dict[str, Any]:
    ref = action.get("ref")
    selected = next((c for c in candidates if c["ref"] == ref), candidates[0] if candidates else None)
    if selected is None:
        raise RuntimeError("No candidate elements to act on")
    bbox = selected["bbox"]
    x = bbox["x"] + bbox["width"] / 2
    y = bbox["y"] + bbox["height"] / 2
    action_type = action.get("action") or action.get("type")
    if action_type == "type":
        await page.mouse.click(x, y)
        await page.keyboard.type(str(action.get("value", "")), delay=20)
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


def ask_action(client: OpenAI, task: dict[str, str], url: str, candidates: list[dict[str, Any]]) -> tuple[dict[str, Any], ProviderMeta]:
    model = os.getenv("FIREWORKS_MODEL", "accounts/fireworks/models/deepseek-v4-pro")
    prompt = {
        "task": f"Start a Google Flights search from {task['origin']} to {task['destination']} departing {task['departDate']}. Choose only the next browser action.",
        "url": url,
        "candidateElements": candidates[:30],
    }
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": "You are a browser agent. Return only valid compact JSON. No markdown. No explanation."},
            {
                "role": "user",
                "content": (
                    "Choose one action using this exact shape: "
                    "{\"action\":\"click|type\",\"ref\":\"candidate ref\",\"value\":\"text for type or null\"}. "
                    f"Input: {json.dumps(prompt)}"
                ),
            },
        ],
        temperature=0,
        max_tokens=256,
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or ""
    return parse_json_object(raw), ProviderMeta(
        model=model,
        raw=raw,
        usage=response.usage.model_dump() if response.usage else {},
    )


class GoogleFlightsTraceAgent(Agent):
    def __init__(self, run_root: Path) -> None:
        self.run_root = run_root
        self.fireworks = fireworks_client()
        self.openai = openai_client()
        self.rows: list[dict[str, Any]] = []
        self.run_reports: list[dict[str, Any]] = []

    async def __call__(self, run: Any) -> None:
        idx = len(self.run_reports)
        task = TASKS[idx % len(TASKS)]
        trace_dir = self.run_root / f"trace_{idx:03d}_{task['origin']}_{task['destination']}"
        trace_dir.mkdir(parents=True, exist_ok=True)
        stage_path = trace_dir / "stage.json"
        write_json(stage_path, {"stage": "agent_entered", "task": task, "prompt": run.prompt_text})
        cdp_url = run.client.binding("browser").url
        write_json(stage_path, {"stage": "binding_read", "task": task, "cdpUrl": cdp_url})

        async with async_playwright() as p:
            write_json(stage_path, {"stage": "playwright_start", "task": task, "cdpUrl": cdp_url})
            browser = await p.chromium.connect_over_cdp(cdp_url)
            try:
                write_json(stage_path, {"stage": "cdp_attached", "task": task})
                context = browser.contexts[0] if browser.contexts else await browser.new_context(viewport={"width": 1280, "height": 800})
                page = context.pages[0] if context.pages else await context.new_page()
                page.set_default_timeout(20000)
                write_json(stage_path, {"stage": "navigating_google_flights", "task": task})
                await page.goto("https://www.google.com/travel/flights", wait_until="domcontentloaded", timeout=45000)
                await page.wait_for_timeout(5000)
                write_json(stage_path, {"stage": "google_flights_loaded", "task": task, "url": page.url})

                candidates = await get_candidates(page)
                write_json(stage_path, {"stage": "candidates_collected", "task": task, "candidateCount": len(candidates), "url": page.url})
                action, provider = ask_action(self.fireworks, task, page.url, candidates)
                write_json(stage_path, {"stage": "action_chosen", "task": task, "action": action})
                selected = await click_or_type(page, candidates, action)
                write_json(stage_path, {"stage": "action_executed", "task": task, "action": action, "selected": selected})

                screenshot_full = trace_dir / "screenshots" / "step_000_fullpage.png"
                screenshot_viewport = trace_dir / "screenshots" / "step_000_viewport.png"
                await page.screenshot(path=screenshot_viewport, full_page=False)
                await page.screenshot(path=screenshot_full, full_page=True)
                crop_element(screenshot_full, trace_dir / "screenshots" / "step_000_element.png", selected["bbox"])

                ax = await page.accessibility.snapshot()
                html = await page.content()
                title = await page.title()
                next_candidates = await get_candidates(page)
                state_text = json.dumps({"title": title, "url": page.url, "elements": candidates[:30]}, sort_keys=True)
                next_state_text = json.dumps({"title": title, "url": page.url, "elements": next_candidates[:30]}, sort_keys=True)
                state_embedding = embed(self.openai, state_text)
                next_state_embedding = embed(self.openai, next_state_text)
                element_embedding = embed(self.openai, json.dumps(selected, sort_keys=True))

                write_json(trace_dir / "accessibility" / "step_000.json", ax)
                (trace_dir / "dom").mkdir(parents=True, exist_ok=True)
                (trace_dir / "dom" / "step_000.html").write_text(html)
                write_jsonl(trace_dir / "network" / "events.jsonl", [{"type": "navigation", "url": page.url, "timestamp": time.time()}])

                row = {
                    "stepIndex": 0,
                    "timestamp": int(time.time() * 1000),
                    "task": task,
                    "url": page.url,
                    "title": title,
                    "stateText": state_text,
                    "stateEmbedding": state_embedding,
                    "action": {"type": action.get("action"), "ref": action.get("ref"), "value": action.get("value")},
                    "selectedElement": selected,
                    "elementEmbedding": element_embedding,
                    "nextStateText": next_state_text,
                    "nextStateEmbedding": next_state_embedding,
                    "reward": 1.0,
                    "artifacts": {
                        "viewportScreenshot": "screenshots/step_000_viewport.png",
                        "fullPageScreenshot": "screenshots/step_000_fullpage.png",
                        "elementScreenshot": "screenshots/step_000_element.png",
                        "accessibility": "accessibility/step_000.json",
                        "dom": "dom/step_000.html",
                    },
                    "model": provider.__dict__,
                }
                write_jsonl(trace_dir / "trace.jsonl", [row])
                write_json(trace_dir / "metadata.json", {"task": task, "prompt": run.prompt_text, "cdpUrlSeen": bool(cdp_url)})
                self.rows.append(row)
                self.run_reports.append({"ok": True, "task": task, "action": row["action"], "url": page.url, "dir": str(trace_dir.relative_to(ROOT))})
                write_json(stage_path, {"stage": "complete", "task": task, "action": row["action"], "url": page.url})
                run.trace.content = f"Collected trace for {task['origin']} to {task['destination']}"
            except Exception as exc:
                self.run_reports.append({"ok": False, "task": task, "error": f"{type(exc).__name__}: {exc}", "dir": str(trace_dir.relative_to(ROOT))})
                run.trace.content = f"Trace collection failed: {type(exc).__name__}: {exc}"
                raise
            finally:
                await browser.close()


async def main() -> None:
    load_dotenv(ROOT / ".env")
    run_id = f"gate_{time.strftime('%Y%m%d_%H%M%S')}"
    out = ARTIFACT_ROOT / run_id
    out.mkdir(parents=True, exist_ok=True)

    agent = GoogleFlightsTraceAgent(out)
    tasks = [
        Task(env="browser", id="todo-create", args={"title": f"OpenHive trace {i}"}, slug=f"google-flights-trace-{i}")
        for i in range(TRACE_COUNT)
    ]
    job = await Taskset("google-flights-trace-gate", tasks).run(
        agent,
        group=1,
        max_concurrent=1,
        rollout_timeout=240,
    )
    policy = train_tiny_policy(agent.rows)
    write_json(out / "policy.json", policy)
    write_jsonl(out / "all_traces.jsonl", agent.rows)
    report = {
        "ok": len(agent.rows) == 3,
        "runDir": str(out.relative_to(ROOT)),
        "jobId": job.id,
        "runs": agent.run_reports,
        "policy": policy["metadata"],
    }
    write_json(out / "report.json", report)
    print(json.dumps(report, indent=2))
    if not report["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
