"""Expert-driven trace collector — Playwright local Chrome gate."""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path
from typing import Any

from embeddings import embed_state
from playwright_runner import INTERACTIVE_SNAPSHOT_JS, PlaywrightRunner
from providers import deterministic_fallback, embed_page_state, embed_selected_element, expert_action
from trace_schema import (
    append_trace_jsonl,
    candidate_from_element,
    normalize_state_text,
    new_run_dir,
    validate_action,
    write_step_artifacts,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS_BASE = REPO_ROOT / "artifacts" / "local-browser-gate"
FLIGHTS_URL = "https://www.google.com/travel/flights"
MAX_STEPS_DEFAULT = 12


def _assign_refs(elements: list[dict]) -> list[dict]:
    out = []
    for i, el in enumerate(elements):
        c = dict(el)
        c["ref"] = f"e{i}"
        out.append(c)
    return out


async def _capture_screenshots(runner: PlaywrightRunner, trace_dir: Path, step_index: int) -> dict[str, Path]:
    page = runner.page
    if not page:
        return {}
    shot_dir = trace_dir / "screenshots" / "_tmp"
    shot_dir.mkdir(parents=True, exist_ok=True)
    tag = f"{step_index:03d}"
    viewport = shot_dir / f"step_{tag}_viewport.png"
    fullpage = shot_dir / f"step_{tag}_fullpage.png"
    await page.screenshot(path=str(viewport), full_page=False)
    await page.screenshot(path=str(fullpage), full_page=True)
    return {"viewport": viewport, "fullpage": fullpage}


async def collect_trace(
    task: dict,
    run_dir: Path,
    *,
    max_steps: int = MAX_STEPS_DEFAULT,
    headless: bool = True,
) -> dict[str, Any]:
    origin = task.get("origin", "BOS")
    dest = task.get("destination", "LAX")
    trace_name = f"trace_{task.get('_index', 0):03d}_{origin}_{dest}"
    trace_dir = run_dir / trace_name
    trace_dir.mkdir(parents=True, exist_ok=True)
    trace_jsonl = trace_dir / "trace.jsonl"
    (trace_dir / "metadata.json").write_text(json.dumps({"task": task}, indent=2))

    import os

    if headless:
        os.environ["OPENHIVE_HEADLESS"] = "1"
    else:
        os.environ["OPENHIVE_HEADLESS"] = "0"

    runner = PlaywrightRunner()
    await runner.start()

    steps: list[dict] = []
    success = False
    try:
        page = runner.page
        assert page is not None
        await page.goto(FLIGHTS_URL, wait_until="domcontentloaded", timeout=45_000)
        await asyncio.sleep(1.0)

        for step_index in range(max_steps):
            t0 = time.time()
            state = await runner.get_state()
            url, title = state["url"], state["title"]
            raw_elements = state.get("accessibilityTree", {}).get("elements", [])
            candidates = [candidate_from_element(c, i) for i, c in enumerate(_assign_refs(raw_elements))]

            state_emb = await embed_page_state(url, title, candidates)
            state_text = normalize_state_text(url, title, candidates)

            action, raw, provider = await expert_action(task, url, title, candidates)
            used_fallback = False
            if not action:
                action = deterministic_fallback(task, candidates)
                used_fallback = True
                provider = "local_fallback"
            ok, err = validate_action(action or {}, candidates)
            if not ok or not action:
                break

            ref = action.get("ref", "")
            selected = next((c for c in candidates if c.get("ref") == ref), candidates[0] if candidates else {})
            element_emb = await embed_selected_element(selected)

            dom_html = await page.content()
            screenshots = await _capture_screenshots(runner, trace_dir, step_index)
            write_step_artifacts(
                trace_dir,
                step_index,
                dom_html=dom_html,
                accessibility={"elements": candidates},
                screenshots=screenshots,
            )

            replay_action = _to_replay_action(action, selected)
            ok_exec, detail = await runner.perform_action(replay_action)
            await asyncio.sleep(0.6)
            next_state = await runner.get_state()
            next_emb = await embed_page_state(next_state["url"], next_state["title"], next_state.get("accessibilityTree"))

            step = {
                "stepIndex": step_index,
                "url": url,
                "title": title,
                "stateText": state_text,
                "stateEmbedding": state_emb,
                "action": {"type": action.get("type"), "ref": ref, "value": action.get("value", "")},
                "selectedElement": selected,
                "elementEmbedding": element_emb,
                "nextStateEmbedding": next_emb,
                "reward": 1.0 if ok_exec else 0.0,
                "provider": provider,
                "timingMs": (time.time() - t0) * 1000,
                "expertRaw": raw[:2000] if raw else "",
                "usedFallback": used_fallback,
                "execDetail": detail,
            }
            append_trace_jsonl(trace_jsonl, step)
            steps.append(step)

            if dest.lower() in next_state.get("title", "").lower() and step_index >= 3:
                success = True
                break
            if step_index >= max_steps - 1:
                success = len(steps) >= 3

    finally:
        await runner.close()

    return {
        "traceName": trace_name,
        "task": task,
        "steps": len(steps),
        "success": success,
        "traceDir": str(trace_dir),
    }


def _to_replay_action(action: dict, selected: dict) -> dict:
    atype = action.get("type") or action.get("action")
    out: dict[str, Any] = {"type": atype}
    if atype == "type":
        out["value"] = action.get("value", "")
        out["text"] = selected.get("text") or selected.get("label") or ""
        out["selector"] = selected.get("selector") or ""
        out["name"] = selected.get("name") or ""
    else:
        out["text"] = selected.get("text") or ""
        out["selector"] = selected.get("selector") or ""
        out["name"] = selected.get("name") or ""
    return out


async def run_collection(
    configs: list[dict],
    *,
    run_id: str | None = None,
    headless: bool = True,
) -> dict[str, Any]:
    run_dir = new_run_dir(ARTIFACTS_BASE, run_id)
    results: list[dict] = []
    all_traces = run_dir / "all_traces.jsonl"

    for i, cfg in enumerate(configs):
        cfg = {**cfg, "_index": i}
        print(f"Collecting {cfg.get('origin')}→{cfg.get('destination')} ({i + 1}/{len(configs)})")
        result = await collect_trace(cfg, run_dir, headless=headless)
        results.append(result)
        with all_traces.open("a") as f:
            f.write(json.dumps({k: v for k, v in result.items() if k != "traceDir"}) + "\n")

    from train import build_policy_json, write_policy_artifact

    policy = build_policy_json([{"harvest": _load_trace_steps(r["traceDir"]), "success": r["success"]} for r in results])
    write_policy_artifact(run_dir / "policy.json", policy)

    report = {
        "runId": run_dir.name,
        "traces": len(results),
        "successful": sum(1 for r in results if r["success"]),
        "results": results,
    }
    (run_dir / "report.json").write_text(json.dumps(report, indent=2))
    return report


def _load_trace_steps(trace_dir: str) -> list[dict]:
    path = Path(trace_dir) / "trace.jsonl"
    if not path.exists():
        return []
    steps = []
    for line in path.read_text().splitlines():
        if line.strip():
            row = json.loads(line)
            steps.append(
                {
                    "url": row.get("url", ""),
                    "title": row.get("title", ""),
                    "state_emb": row.get("stateEmbedding") if isinstance(row.get("stateEmbedding"), list) else [],
                    "action": row.get("action", {}),
                }
            )
    return steps


def _load_configs(limit: int | None) -> list[dict]:
    cfg_path = REPO_ROOT / "configs" / "collection_configs.json"
    if cfg_path.exists():
        configs = json.loads(cfg_path.read_text())
    else:
        from datagen.synthetic import generate_configs

        configs = generate_configs(limit=limit or 15)
    if limit:
        configs = configs[:limit]
    return configs


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenHive Playwright trace collector")
    parser.add_argument("--gate", action="store_true", help="Run local-browser-gate collection")
    parser.add_argument("--limit", type=int, default=3, help="Max traces to collect")
    parser.add_argument("--headed", action="store_true", help="Show browser window")
    parser.add_argument("--run-id", type=str, default=None)
    args = parser.parse_args()

    if not args.gate:
        parser.error("Use --gate to run collection")

    configs = _load_configs(args.limit)
    report = asyncio.run(run_collection(configs, run_id=args.run_id, headless=not args.headed))
    print(json.dumps({"runId": report["runId"], "traces": report["traces"], "successful": report["successful"]}, indent=2))


if __name__ == "__main__":
    main()
