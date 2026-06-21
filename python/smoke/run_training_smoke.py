"""Local smoke test for the OpenHive trace/training plan.

This does not launch a full browser collection job. It validates the external
providers, writes a framework-agnostic multimodal trace bundle, and trains a
tiny policy from that bundle.
"""

from __future__ import annotations

import base64
import json
import math
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from exa_py import Exa
from openai import OpenAI
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = ROOT / "artifacts" / "smoke"


@dataclass
class BBox:
    x: int
    y: int
    width: int
    height: int


@dataclass
class CandidateElement:
    ref: str
    role: str
    text: str
    bbox: BBox
    selector: str
    visible: bool = True
    enabled: bool = True


@dataclass
class Action:
    type: str
    ref: str | None = None
    value: str | None = None


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def create_screenshot(path: Path, selected: CandidateElement | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (1280, 720), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 1280, 88), fill=(245, 247, 250))
    draw.text((40, 32), "Google Flights smoke page", fill=(20, 24, 32))
    boxes = [
        (CandidateElement("origin", "textbox", "Where from?", BBox(80, 160, 260, 56), "#origin"), (235, 244, 255)),
        (CandidateElement("destination", "textbox", "Where to?", BBox(360, 160, 260, 56), "#destination"), (235, 255, 244)),
        (CandidateElement("date", "button", "Departure date", BBox(640, 160, 220, 56), "#date"), (255, 248, 220)),
        (CandidateElement("search", "button", "Search", BBox(880, 160, 160, 56), "#search"), (66, 133, 244)),
    ]
    for element, fill in boxes:
        b = element.bbox
        draw.rounded_rectangle((b.x, b.y, b.x + b.width, b.y + b.height), radius=8, fill=fill, outline=(180, 190, 205))
        draw.text((b.x + 16, b.y + 18), element.text, fill=(20, 24, 32))
    if selected:
        b = selected.bbox
        draw.rectangle((b.x - 4, b.y - 4, b.x + b.width + 4, b.y + b.height + 4), outline=(255, 0, 0), width=4)
    image.save(path)


def crop_element(full_page: Path, out_path: Path, bbox: BBox) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(full_page) as image:
        image.crop((bbox.x, bbox.y, bbox.x + bbox.width, bbox.y + bbox.height)).save(out_path)


def b64_image(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def openai_client() -> OpenAI:
    return OpenAI(api_key=require_env("OPENAI_API_KEY"))


def fireworks_client() -> OpenAI:
    api_key = os.getenv("FIREWORKS_API_KEY") or os.getenv("DEEPSEEK_API_KEY")
    if not api_key:
        raise RuntimeError("Missing FIREWORKS_API_KEY or DEEPSEEK_API_KEY")
    base_url = os.getenv("FIREWORKS_BASE_URL") or os.getenv("DEEPSEEK_BASE_URL") or "https://api.fireworks.ai/inference/v1"
    return OpenAI(api_key=api_key, base_url=base_url)


def embed(client: OpenAI, text: str) -> list[float]:
    model = os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")
    return client.embeddings.create(model=model, input=text).data[0].embedding


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


def run_hud_smoke() -> dict[str, Any]:
    hud_env = Path.home() / ".hud" / ".env"
    result: dict[str, Any] = {
        "credentials_file": str(hud_env),
        "credentials_file_exists": hud_env.exists(),
    }
    try:
        completed = subprocess.run(
            [sys.executable, "-m", "hud", "jobs"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        result.update(
            {
                "cli_exit_code": completed.returncode,
                "cli_stdout": completed.stdout.strip(),
                "cli_stderr": completed.stderr.strip(),
                "ok": completed.returncode == 0,
            }
        )
    except Exception as exc:
        result.update({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    return result


def ask_model_action(client: OpenAI, model: str, elements: list[CandidateElement]) -> tuple[dict[str, Any], dict[str, Any]]:
    payload = {
        "task": "Book a public Google Flights search from BOS to LAX departing July 15. Choose the first action.",
        "url": "https://www.google.com/travel/flights",
        "elements": [asdict(e) for e in elements],
    }
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": "You are a browser agent. Return only valid compact JSON. No markdown. No explanation."},
            {
                "role": "user",
                "content": (
                    "Choose exactly one browser action from these candidates. "
                    "Allowed shape: {\"action\":\"click|type\",\"ref\":\"...\",\"value\":\"...\"}. "
                    f"Input: {json.dumps(payload)}"
                ),
            },
        ],
        temperature=0,
        max_tokens=128,
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or ""
    usage = response.usage.model_dump() if response.usage else {}
    return parse_json_object(raw), {"model": model, "raw": raw, "usage": usage}


def ask_expert_action(client: OpenAI, elements: list[CandidateElement]) -> tuple[dict[str, Any], dict[str, Any]]:
    attempts: list[dict[str, Any]] = []
    models = [
        os.getenv("FIREWORKS_MODEL", "accounts/fireworks/models/deepseek-v4-pro"),
        os.getenv("FIREWORKS_MINIMAX_MODEL", "accounts/fireworks/models/minimax-m3"),
    ]
    for model in models:
        try:
            action, metadata = ask_model_action(client, model, elements)
            metadata["attempts"] = attempts
            return action, metadata
        except Exception as exc:
            attempts.append({"model": model, "error": f"{type(exc).__name__}: {exc}"})
    raise RuntimeError(f"All expert action models failed: {attempts}")


def ask_minimax_image_check(client: OpenAI, screenshot: Path) -> dict[str, Any]:
    model = os.getenv("FIREWORKS_MINIMAX_MODEL", "accounts/fireworks/models/minimax-m3")
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": "Return only valid compact JSON. No markdown. No explanation."},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Does this synthetic browser screenshot show a flight search UI? Return {\"flight_ui\":true|false}."},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64_image(screenshot)}"}},
                ],
            },
        ],
        temperature=0,
        max_tokens=128,
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or ""
    return {
        "model": model,
        "raw": raw,
        "parsed": parse_json_object(raw),
        "usage": response.usage.model_dump() if response.usage else {},
    }


def run_exa_smoke() -> dict[str, Any]:
    exa = Exa(api_key=require_env("EXA_API_KEY"))
    results = exa.search(
        "official Google Flights help search flights",
        type="auto",
        num_results=3,
        contents={"highlights": True},
    )
    return {
        "result_count": len(results.results),
        "results": [
            {
                "title": r.title,
                "url": r.url,
                "highlight_count": len(getattr(r, "highlights", None) or []),
            }
            for r in results.results
        ],
    }


def train_tiny_policy(trace_rows: list[dict[str, Any]]) -> dict[str, Any]:
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    threshold = 0.88

    def node_for(row: dict[str, Any]) -> int:
        emb = row["stateEmbedding"]
        for node in nodes:
            if row["url"] == node["url"] and cosine(emb, node["centroid"]) >= threshold:
                node["members"] += 1
                n = node["members"]
                node["centroid"] = [(old * (n - 1) + new) / n for old, new in zip(node["centroid"], emb, strict=True)]
                return int(node["id"])
        node_id = len(nodes)
        nodes.append({"id": node_id, "url": row["url"], "centroid": emb, "members": 1, "actions": []})
        return node_id

    for row in trace_rows:
        source = node_for(row)
        edge = {
            "from": source,
            "action": row["action"],
            "elementCentroid": row.get("elementEmbedding"),
            "successRate": row.get("reward", 1.0),
            "support": 1,
        }
        nodes[source]["actions"].append(edge)
        edges.append(edge)

    return {
        "nodes": nodes,
        "edges": edges,
        "metadata": {
            "trainer": "tiny-smoke",
            "stateThreshold": threshold,
            "nodeCount": len(nodes),
            "edgeCount": len(edges),
        },
    }


def main() -> None:
    load_dotenv(ROOT / ".env")
    run_id = f"smoke_{time.strftime('%Y%m%d_%H%M%S')}"
    out = ARTIFACT_ROOT / run_id
    out.mkdir(parents=True, exist_ok=True)

    elements = [
        CandidateElement("origin", "textbox", "Where from?", BBox(80, 160, 260, 56), "#origin"),
        CandidateElement("destination", "textbox", "Where to?", BBox(360, 160, 260, 56), "#destination"),
        CandidateElement("date", "button", "Departure date", BBox(640, 160, 220, 56), "#date"),
        CandidateElement("search", "button", "Search", BBox(880, 160, 160, 56), "#search"),
    ]
    element_by_ref = {e.ref: e for e in elements}

    screenshot_full = out / "screenshots" / "step_000_fullpage.png"
    screenshot_viewport = out / "screenshots" / "step_000_viewport.png"
    create_screenshot(screenshot_full, elements[0])
    create_screenshot(screenshot_viewport, elements[0])
    crop_element(screenshot_full, out / "screenshots" / "step_000_element.png", elements[0].bbox)

    hud_result = run_hud_smoke()
    fw = fireworks_client()
    oa = openai_client()
    action_json, deepseek_meta = ask_expert_action(fw, elements)
    minimax_image = ask_minimax_image_check(fw, screenshot_viewport)
    exa_result = run_exa_smoke()

    selected = element_by_ref.get(action_json.get("ref"), elements[0])
    state_text = "Google Flights page with origin, destination, date, and search controls"
    next_state_text = f"After action {action_json}, selected {selected.role} {selected.text}"
    state_embedding = embed(oa, state_text)
    next_state_embedding = embed(oa, next_state_text)
    element_embedding = embed(oa, f"{selected.role}: {selected.text}")

    trace_rows = [
        {
            "stepIndex": 0,
            "timestamp": int(time.time() * 1000),
            "url": "https://www.google.com/travel/flights",
            "title": "Google Flights smoke page",
            "viewport": {"width": 1280, "height": 720, "deviceScaleFactor": 1},
            "stateText": state_text,
            "stateEmbedding": state_embedding,
            "action": {
                "type": action_json.get("action", "click"),
                "ref": action_json.get("ref", selected.ref),
                "value": action_json.get("value"),
            },
            "selectedElement": asdict(selected),
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
            "model": deepseek_meta,
        }
    ]

    write_json(out / "accessibility" / "step_000.json", {"role": "document", "name": "Google Flights smoke page", "children": [asdict(e) for e in elements]})
    (out / "dom").mkdir(parents=True, exist_ok=True)
    (out / "dom" / "step_000.html").write_text(
        "<main><input id='origin' aria-label='Where from?'><input id='destination' aria-label='Where to?'><button id='date'>Departure date</button><button id='search'>Search</button></main>\n"
    )
    write_jsonl(out / "network" / "events.jsonl", [{"type": "navigation", "url": "https://www.google.com/travel/flights", "status": 200}])
    write_jsonl(out / "trace.jsonl", trace_rows)

    policy = train_tiny_policy(trace_rows)
    write_json(out / "policy.json", policy)

    metadata = {
        "runId": run_id,
        "task": "Smoke test trace for BOS to LAX Google Flights workflow",
        "params": {"origin": "BOS", "destination": "LAX", "departDate": "2026-07-15"},
        "providers": {
            "hud": hud_result,
            "deepseek": {"ok": action_json.get("action") in {"click", "type"}, **deepseek_meta},
            "minimaxImage": minimax_image,
            "openaiEmbedding": {"model": os.getenv("EMBEDDING_MODEL", "text-embedding-3-small"), "dimensions": len(state_embedding)},
            "exa": exa_result,
        },
        "artifacts": {
            "trace": "trace.jsonl",
            "policy": "policy.json",
        },
    }
    write_json(out / "metadata.json", metadata)

    report = {
        "ok": all(
            [
                hud_result.get("ok"),
                action_json.get("action") in {"click", "type"},
                minimax_image["parsed"].get("flight_ui") is True,
                len(state_embedding) == 1536,
                exa_result["result_count"] > 0,
                policy["metadata"]["nodeCount"] >= 1,
            ]
        ),
        "runDir": str(out.relative_to(ROOT)),
        "checks": {
            "hud": hud_result.get("ok"),
            "deepseekAction": action_json,
            "minimaxImage": minimax_image["parsed"],
            "embeddingDimensions": len(state_embedding),
            "exaResults": exa_result["result_count"],
            "policyNodes": policy["metadata"]["nodeCount"],
            "policyEdges": policy["metadata"]["edgeCount"],
        },
    }
    write_json(out / "report.json", report)
    print(json.dumps(report, indent=2))
    if not report["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
