"""Framework-agnostic trace step schema for collection, training, and replay."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, TypedDict


class BBox(TypedDict, total=False):
    x: float
    y: float
    width: float
    height: float


class ActionRecord(TypedDict, total=False):
    type: str
    ref: str
    value: str
    text: str
    selector: str
    name: str
    url: str


class ElementRecord(TypedDict, total=False):
    ref: str
    role: str
    text: str
    bbox: BBox


class ScreenshotPaths(TypedDict, total=False):
    viewport: str
    fullpage: str
    element: str


class StepRecord(TypedDict, total=False):
    stepIndex: int
    url: str
    title: str
    stateText: str
    stateEmbedding: list[float]
    action: ActionRecord
    selectedElement: ElementRecord
    elementEmbedding: list[float]
    nextStateEmbedding: list[float]
    reward: float
    provider: str
    timingMs: float
    domPath: str
    accessibilityPath: str
    expertRaw: str
    usedFallback: bool


def normalize_state_text(url: str, title: str, candidates: list[dict]) -> str:
    lines = [f"url:{url}", f"title:{title}"]
    for c in candidates[:40]:
        ref = c.get("ref", "")
        role = c.get("role", "")
        text = (c.get("text") or c.get("label") or "")[:80]
        lines.append(f"{ref} {role} {text}".strip())
    return "\n".join(lines)


def candidate_from_element(el: dict, index: int) -> dict:
    ref = el.get("ref") or f"e{index}"
    return {
        "ref": ref,
        "role": el.get("role") or el.get("tag") or "",
        "text": (el.get("text") or el.get("label") or "")[:120],
        "selector": el.get("selector") or "",
        "name": el.get("name") or "",
        "bbox": el.get("bbox") or {},
    }


def validate_action(action: dict, candidates: list[dict]) -> tuple[bool, str]:
    atype = action.get("action") or action.get("type") or ""
    if atype not in ("click", "type"):
        return False, f"invalid action type: {atype}"
    ref = action.get("ref", "")
    refs = {c.get("ref") for c in candidates}
    if ref and ref not in refs:
        return False, f"ref {ref} not in candidates"
    if atype == "type" and not isinstance(action.get("value"), str):
        return False, "type action requires string value"
    return True, ""


def append_trace_jsonl(path: Path, step: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serializable = _json_safe(step)
    with path.open("a") as f:
        f.write(json.dumps(serializable) + "\n")


def _json_safe(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        if obj and isinstance(obj[0], float):
            return f"[{len(obj)} dims]"
        return [_json_safe(v) for v in obj]
    return obj


def write_step_artifacts(
    trace_dir: Path,
    step_index: int,
    *,
    dom_html: str = "",
    accessibility: dict | list | None = None,
    network_events: list[dict] | None = None,
    screenshots: dict[str, Path] | None = None,
) -> None:
    step_tag = f"{step_index:03d}"
    if dom_html:
        dom_path = trace_dir / "dom" / f"step_{step_tag}.html"
        dom_path.parent.mkdir(parents=True, exist_ok=True)
        dom_path.write_text(dom_html)
    if accessibility is not None:
        a11y_path = trace_dir / "accessibility" / f"step_{step_tag}.json"
        a11y_path.parent.mkdir(parents=True, exist_ok=True)
        a11y_path.write_text(json.dumps(accessibility, indent=2))
    if network_events:
        net_path = trace_dir / "network" / "events.jsonl"
        net_path.parent.mkdir(parents=True, exist_ok=True)
        with net_path.open("a") as f:
            for ev in network_events:
                f.write(json.dumps(ev) + "\n")
    if screenshots:
        shot_dir = trace_dir / "screenshots"
        shot_dir.mkdir(parents=True, exist_ok=True)
        for kind, src in screenshots.items():
            if src.exists():
                dest = shot_dir / f"step_{step_tag}_{kind}.png"
                dest.write_bytes(src.read_bytes())


def new_run_dir(base: Path, run_id: str | None = None) -> Path:
    rid = run_id or time.strftime("%Y%m%d_%H%M%S")
    run_dir = base / rid
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir
