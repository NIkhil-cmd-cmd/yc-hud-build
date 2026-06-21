"""Shared headed Playwright browser for agent clicks/types (CDP-grade interaction)."""

from __future__ import annotations

import asyncio
import os
from typing import Any

from playwright_runner import PlaywrightRunner

_runner: PlaywrightRunner | None = None
_lock = asyncio.Lock()


def agent_playwright_enabled() -> bool:
    return os.environ.get("OPENHIVE_AGENT_PLAYWRIGHT", "1") != "0"


async def get_runner() -> PlaywrightRunner:
    global _runner
    async with _lock:
        if _runner is None or _runner.page is None:
            if _runner:
                await _runner.close()
            os.environ.setdefault("OPENHIVE_HEADLESS", "0")
            _runner = PlaywrightRunner()
            await _runner.start()
        return _runner


async def close_runner() -> None:
    global _runner
    async with _lock:
        if _runner:
            await _runner.close()
            _runner = None


async def sync_url(url: str) -> None:
    if not url or url in ("about:blank", "about:newtab"):
        return
    runner = await get_runner()
    page = runner.page
    if not page:
        return
    current = page.url.rstrip("/")
    target = url.rstrip("/")
    if current != target:
        await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
        await asyncio.sleep(0.4)


async def perform_action(action: dict[str, Any], *, url: str | None = None) -> dict[str, Any]:
    """Run one action in headed Chromium. Returns {ok, detail, url, title}."""
    if url:
        await sync_url(url)
    runner = await get_runner()
    ok, detail = await runner.perform_action(action)
    state = await runner.get_state()
    return {
        "ok": ok,
        "detail": detail,
        "url": state.get("url", ""),
        "title": state.get("title", ""),
    }


async def get_state() -> dict[str, Any]:
    runner = await get_runner()
    return await runner.get_state()
