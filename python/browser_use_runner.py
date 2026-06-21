"""Run tasks with the browser-use library (Playwright + vision LLM agent)."""

from __future__ import annotations

import asyncio
import os
import time
import traceback
from pathlib import Path
from typing import Any, Awaitable, Callable

from log_config import log_event, setup_logging

log = setup_logging("openhive.browser_use")

SendFn = Callable[[dict[str, Any]], Awaitable[None]]

OPENHIVE_SYSTEM_EXTENSION = """
You are OpenHive's browser agent. Act like a skilled human user, not a script.

Interaction rules:
- After typing in search boxes, comboboxes, or airport fields, ALWAYS click the matching
  autocomplete suggestion in the dropdown. Never rely on Enter alone.
- On Google Flights: pick origin from suggestions, pick destination from suggestions,
  open the departure date picker, click the exact date, confirm, then click Search
  (not only Done on the calendar).
- Wait for SPAs to finish loading before the next action. If a search yields nothing,
  scroll down once, then retry Search or re-open the form fields.
- Dismiss cookie/consent banners when they block the UI (Accept, Agree, Close, Got it).
- Prefer clicking visible buttons and links over keyboard shortcuts.
- If you repeat the same wait/scroll more than twice, change strategy: clear a field,
  retype, pick autocomplete again, or navigate back to the start URL.
- Do NOT use the wait action more than once per task. If the page looks loaded, act.
- Use extract only when you need specific data; prefer visible UI actions to complete goals.
- Call done only when the user's goal is visibly satisfied on screen.
"""


def browser_use_enabled() -> bool:
    """External Playwright Chromium — opt-in only (OPENHIVE_USE_BROWSER_USE=1)."""
    return os.environ.get("OPENHIVE_USE_BROWSER_USE", "0") == "1"


def _headless() -> bool:
    return os.environ.get("OPENHIVE_HEADLESS", "0") == "1"


def _use_judge() -> bool:
    return os.environ.get("OPENHIVE_BROWSER_USE_JUDGE", "0") == "1"


def _default_max_steps() -> int:
    return int(os.getenv("OPENHIVE_AGENT_MAX_STEPS", "40"))


def _openhive_profile_dir() -> Path:
    root = Path.home() / "Library" / "Application Support" / "OpenHive" / "browser-use-profile"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _resolve_chromium_executable() -> str | None:
    """Return Playwright Chromium path, or None to use system Chrome channel."""
    import glob

    if os.environ.get("OPENHIVE_USE_SYSTEM_CHROME", "1") == "1":
        system_chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        if system_chrome.is_file():
            return None  # let BrowserProfile use channel=chrome

    override = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH", "").strip()
    if override and Path(override).is_file():
        return override

    cache_root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "").strip()
    if not cache_root:
        cache_root = str(Path.home() / "Library" / "Caches" / "ms-playwright")
    cache = Path(cache_root).expanduser()

    patterns = [
        str(cache / "chromium-*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
        str(cache / "chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium"),
        str(cache / "chromium-*/chrome-linux*/chrome"),
        str(cache / "chromium-*/chrome-win/chrome.exe"),
    ]
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        if matches and Path(matches[-1]).is_file():
            return matches[-1]

    system_chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if system_chrome.is_file():
        return None
    raise RuntimeError("Chromium not found. Run: python -m playwright install chromium")


def _model() -> str:
    return os.getenv("OPENHIVE_AGENT_MODEL") or os.getenv("OPENAI_AGENT_MODEL") or "gpt-4o"


def _make_llm():
    from browser_use import ChatOpenAI

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY required for browser-use agent")
    return ChatOpenAI(model=_model(), api_key=api_key, temperature=0.15)


def _make_browser_profile(storage_state: dict[str, Any] | None = None):
    from browser_use.browser.profile import BrowserChannel, BrowserProfile

    executable = _resolve_chromium_executable()
    has_cookies = bool(storage_state and storage_state.get("cookies"))
    profile_kwargs: dict[str, Any] = {
        "headless": _headless(),
        "disable_security": False,
        "keep_alive": False,
        "window_size": {"width": 1440, "height": 920},
        "wait_between_actions": 0.25,
        "wait_for_network_idle_page_load_time": 1.2,
        "minimum_wait_page_load_time": 0.5,
        "highlight_elements": True,
        "enable_default_extensions": True,
    }
    # Fresh profile when injecting Nook cookies — avoids lock conflicts + stale state
    if has_cookies:
        profile_kwargs["storage_state"] = storage_state
    else:
        profile_kwargs["user_data_dir"] = _openhive_profile_dir()

    if executable:
        profile_kwargs["executable_path"] = executable
    else:
        profile_kwargs["channel"] = BrowserChannel.CHROME

    return BrowserProfile(**profile_kwargs)


def _enrich_task(
    task: str,
    *,
    start_url: str | None,
    page_url: str | None,
    page_title: str | None,
) -> str:
    parts: list[str] = []
    ctx_url = page_url or start_url
    if ctx_url and ctx_url not in ("about:blank", "about:newtab", ""):
        ctx = f"The user's Nook browser tab is on {ctx_url}."
        if page_title:
            ctx += f' Page title: "{page_title}".'
        parts.append(ctx)
    if start_url and start_url not in task:
        parts.append(f"First navigate to {start_url}.")
    parts.append(task)
    return " ".join(parts)


def _flight_task_string(task: dict[str, str]) -> str:
    origin = task["origin"]
    dest = task["destination"]
    depart = task["departDate"]
    return (
        f"On Google Flights, book a one-way flight from {origin} to {dest} departing {depart}. "
        f"Type '{origin}' in 'Where from?' and click the matching airport in the autocomplete dropdown. "
        f"Type '{dest}' in 'Where to?' and click the matching airport in autocomplete. "
        f"Open the departure date picker, select {depart}, confirm the date, then click Search. "
        f"Finish when the search results page lists priced flights from {origin} to {dest}."
    )


def _format_step_action(output: Any) -> str:
    if output is None:
        return "step"
    if hasattr(output, "model_dump"):
        try:
            data = output.model_dump()
            if isinstance(data, dict):
                for key in ("action", "actions", "done", "navigate", "click", "input", "wait", "extract"):
                    if key in data and data[key]:
                        return f"{key}: {str(data[key])[:100]}"
                return str(data)[:120]
        except Exception:
            pass
    return type(output).__name__


async def run_browser_use_task(
    send: SendFn,
    task: str,
    *,
    start_url: str | None = None,
    page_url: str | None = None,
    page_title: str | None = None,
    storage_state: dict[str, Any] | None = None,
    max_steps: int | None = None,
) -> dict[str, Any]:
    """Run a natural-language task with browser-use Agent."""
    from browser_use import Agent, Browser

    max_steps = max_steps or _default_max_steps()
    task = _enrich_task(task, start_url=start_url, page_url=page_url, page_title=page_title)
    if start_url and start_url not in task:
        task = f"First navigate to {start_url}. {task}"

    t0 = time.time()
    await send({"type": "agent_progress", "message": "Starting browser-use agent…"})
    llm = _make_llm()
    model = _model()
    profile = _make_browser_profile(storage_state)
    browser = Browser(browser_profile=profile)

    cookie_count = len((storage_state or {}).get("cookies") or [])
    await send(
        {
            "type": "execute_started",
            "backend": "browser-use",
            "workflowName": task[:80],
            "agentMode": "browser-use",
            "cookiesSynced": cookie_count,
        }
    )

    last_url = page_url or start_url or ""

    async def on_step(state, output, step: int) -> None:
        nonlocal last_url
        last_url = getattr(state, "url", None) or last_url
        title = getattr(state, "title", None) or ""
        elapsed_ms = int((time.time() - t0) * 1000)
        est_tokens = step * 1400
        await send(
            {
                "type": "agent_step",
                "step": step,
                "provider": "browser-use",
                "model": model,
                "action": _format_step_action(output),
                "url": last_url,
                "title": title,
                "mirrorUrl": False,
            }
        )
        await send(
            {
                "type": "run_metric",
                "tokens": est_tokens,
                "tier": 3,
                "elapsedMs": elapsed_ms,
                "runType": "agent",
                "workflowName": task[:80],
            }
        )

    agent = Agent(
        task=task,
        llm=llm,
        browser=browser,
        register_new_step_callback=on_step,
        extend_system_message=OPENHIVE_SYSTEM_EXTENSION,
        use_vision=True,
        vision_detail_level="high",
        max_actions_per_step=5,
        step_timeout=180,
        directly_open_url=bool(start_url),
        flash_mode=False,
        use_thinking=True,
        use_judge=_use_judge(),
        enable_planning=True,
        planning_replan_on_stall=2,
        loop_detection_enabled=True,
        page_extraction_llm=llm,
    )

    try:
        log_event(
            log,
            "browser_use_start",
            task=task[:120],
            model=model,
            max_steps=max_steps,
            cookies=cookie_count,
        )
        history = await agent.run(max_steps=max_steps)
        success = False
        if hasattr(history, "is_successful"):
            try:
                success = bool(history.is_successful())
            except Exception:
                success = not history.has_errors()
        elif hasattr(history, "has_errors"):
            success = not history.has_errors()

        final_text = ""
        if hasattr(history, "final_result"):
            try:
                final_text = history.final_result() or ""
            except Exception:
                final_text = ""

        steps = step_count(history)
        elapsed = round(time.time() - t0, 1)
        total_tokens = steps * 1400

        if not success and final_text:
            hay = final_text.lower()
            if any(x in hay for x in ("flight", "price", "$", "depart", "completed", "success")):
                success = True
        if not success and last_url:
            try:
                from smoke.run_local_browser_trace_gate import reached_results

                success = reached_results({"url": last_url, "title": "", "text": final_text})
            except Exception:
                pass

        await send(
            {
                "type": "run_metric",
                "tokens": total_tokens,
                "tier": 3,
                "elapsedMs": int(elapsed * 1000),
                "runType": "agent",
                "workflowName": task[:80],
            }
        )
        await send(
            {
                "type": "trajectory_complete",
                "success": success,
                "steps": steps,
                "finalUrl": last_url,
                "reason": "browser-use",
                "elapsedSec": elapsed,
                "result": final_text[:800],
                "mirrorUrl": True,
            }
        )
        await send({"type": "execute_done", "hudStatus": "ok" if success else "partial"})
        log_event(log, "browser_use_done", success=success, steps=steps, elapsed=elapsed)
        return {
            "success": success,
            "steps": steps,
            "finalUrl": last_url,
            "elapsedSec": elapsed,
            "result": final_text,
        }
    except asyncio.CancelledError:
        log_event(log, "browser_use_cancelled")
        await send({"type": "execute_cancelled"})
        raise
    except Exception as exc:
        log.error("browser_use_failed\n%s", traceback.format_exc())
        await send({"type": "error", "message": f"browser-use: {str(exc)[:200]}"})
        await send(
            {
                "type": "trajectory_complete",
                "success": False,
                "reason": "error",
                "steps": 0,
                "elapsedSec": round(time.time() - t0, 1),
            }
        )
        await send({"type": "execute_done", "hudStatus": "error"})
        return {"success": False, "error": str(exc)}
    finally:
        try:
            await browser.close()
        except Exception:
            pass


async def run_flight_trajectory(
    send: SendFn,
    task: dict[str, str],
    *,
    storage_state: dict[str, Any] | None = None,
    page_url: str | None = None,
    page_title: str | None = None,
    max_steps: int | None = None,
) -> dict[str, Any]:
    goal = _flight_task_string(task)
    ctx_url = page_url if page_url and "travel/flights" in page_url else None
    return await run_browser_use_task(
        send,
        goal,
        start_url="https://www.google.com/travel/flights",
        page_url=ctx_url,
        page_title=page_title if ctx_url else None,
        storage_state=storage_state,
        max_steps=max_steps,
    )


def step_count(history: Any) -> int:
    if hasattr(history, "agent_steps"):
        steps = history.agent_steps()
        if isinstance(steps, list):
            return len(steps)
    if hasattr(history, "history") and isinstance(history.history, list):
        return len(history.history)
    return 0
