"""Playwright-backed browser automation — real clicks, typing, navigation."""

from __future__ import annotations

import asyncio
import os
import re
from typing import Any, Callable

from playwright.async_api import Browser, BrowserContext, Locator, Page, async_playwright

# Selectors recorded from WebKit that are too generic — prefer visible text instead.
GENERIC_SELECTORS = frozenset(
    {
        "",
        "button",
        "#button",
        "#search",
        "input",
        "#input",
        "#submit",
        "a",
    }
)

INTERACTIVE_SNAPSHOT_JS = """
() => {
  const limit = 60;
  const selectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [role="searchbox"], [onclick], [tabindex]';
  const elements = document.querySelectorAll(selectors);
  const results = [];
  for (const el of elements) {
    if (results.length >= limit) break;
    if (el.offsetParent === null && el.style.display !== 'contents' && !el.closest('label')) continue;
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute('type') || '';
    const text = (el.textContent || '').trim().substring(0, 80);
    const value = el.value || '';
    const ariaLabel = el.getAttribute('aria-label') || '';
    const placeholder = el.getAttribute('placeholder') || '';
    const name = el.getAttribute('name') || '';
    const id = el.id || '';
    const label = text || ariaLabel || placeholder || value || name;
    if (!label && tag === 'input' && type === 'hidden') continue;
    let selector = '';
    if (id) selector = '#' + CSS.escape(id);
    else if (name) selector = tag + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
    else if (ariaLabel) selector = tag + '[aria-label="' + ariaLabel.replace(/"/g, '\\\\"') + '"]';
    else if (placeholder) selector = tag + '[placeholder="' + placeholder.replace(/"/g, '\\\\"') + '"]';
    results.push({
      tag,
      text: label.substring(0, 60),
      role: el.getAttribute('role') || '',
      name,
      selector,
    });
  }
  return results;
}
"""

CLICK_BY_TEXT_JS = """
(query) => {
  const q = query.toLowerCase().trim();
  if (!q) return null;
  const candidates = document.querySelectorAll(
    'a, button, input[type="submit"], input[type="button"], [role="button"], [role="link"], [role="tab"], label, ytd-button-renderer button, tp-yt-paper-button'
  );
  let best = null;
  let bestScore = Infinity;
  for (const el of candidates) {
    if (el.offsetParent === null && getComputedStyle(el).visibility === 'hidden') continue;
    const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
    if (!label) continue;
    const lower = label.toLowerCase();
    if (lower === q) {
      best = el;
      break;
    }
    if (lower.includes(q) && label.length < bestScore) {
      best = el;
      bestScore = label.length;
    }
  }
  if (!best) return null;
  const clicked = (best.innerText || best.value || best.getAttribute('aria-label') || best.getAttribute('title') || '').trim();
  best.scrollIntoView({ block: 'center', inline: 'center' });
  best.click();
  return clicked.slice(0, 100);
}
"""


class PlaywrightRunner:
    """Single Chromium session for workflow replay."""

    def __init__(self) -> None:
        self._pw = None
        self._browser: Browser | None = None
        self._context: BrowserContext | None = None
        self._page: Page | None = None
        self._closed = False

    @property
    def page(self) -> Page | None:
        return self._page

    async def start(self) -> None:
        headless = os.environ.get("OPENHIVE_HEADLESS", "0") == "1"
        self._pw = await async_playwright().start()
        self._browser = await self._pw.chromium.launch(headless=headless)
        self._context = await self._browser.new_context(viewport={"width": 1280, "height": 900})
        self._page = await self._context.new_page()
        self._page.set_default_timeout(15_000)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            if self._context:
                await self._context.close()
            if self._browser:
                await self._browser.close()
            if self._pw:
                await self._pw.stop()
        except Exception:
            pass
        self._page = None
        self._context = None
        self._browser = None
        self._pw = None

    async def get_state(self) -> dict[str, Any]:
        page = self._page
        if not page:
            return {"url": "", "title": "", "accessibilityTree": {"elements": [], "count": 0}}
        try:
            elements = await page.evaluate(INTERACTIVE_SNAPSHOT_JS)
        except Exception:
            elements = []
        return {
            "url": page.url,
            "title": await page.title(),
            "accessibilityTree": {"elements": elements, "count": len(elements)},
        }

    async def perform_action(self, action: dict[str, Any]) -> tuple[bool, str]:
        page = self._page
        if not page:
            return False, "No browser page"

        atype = action.get("type", "")
        try:
            if atype == "navigate":
                return await self._navigate(page, action)
            if atype == "click":
                return await self._click(page, action)
            if atype in ("type", "fill"):
                return await self._type(page, action)
            return False, f"Unknown action: {atype}"
        except Exception as exc:
            return False, str(exc)[:200]

    async def _navigate(self, page: Page, action: dict[str, Any]) -> tuple[bool, str]:
        url = action.get("url", "")
        if not url or url in ("about:blank", "about:newtab"):
            return True, "Skipped blank navigate"
        current = page.url.rstrip("/")
        target = url.rstrip("/")
        if current == target:
            return True, "Already on page"
        await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
        await asyncio.sleep(0.5)
        return True, f"Navigated to {url}"

    async def _click(self, page: Page, action: dict[str, Any]) -> tuple[bool, str]:
        selector = (action.get("selector") or "").strip()
        text = (action.get("text") or "").strip()
        name = (action.get("name") or "").strip()
        role = (action.get("role") or "").strip()

        # Prefer visible text when we have a label like "Search" or "Restart"
        prefer_text = bool(text) and (
            not selector
            or selector.lower() in GENERIC_SELECTORS
            or (len(text) >= 3 and text.lower() not in ("input", "button"))
        )

        if prefer_text:
            ok, detail = await self._click_by_text(page, text)
            if ok:
                return True, detail

        if selector and selector.lower() not in GENERIC_SELECTORS:
            ok, detail = await self._click_locator(page.locator(selector).first, f"selector: {selector[:80]}")
            if ok:
                return True, detail

        if text:
            ok, detail = await self._click_by_text(page, text)
            if ok:
                return True, detail

        if role:
            ok, detail = await self._click_by_role(page, role, text or name)
            if ok:
                return True, detail

        if name and name.lower() not in ("button", "input", "a"):
            loc = page.locator(
                f'[name="{name}"], #{name}, [aria-label="{name}"], [aria-label*="{name}" i], '
                f'[placeholder*="{name}" i]'
            ).first
            ok, detail = await self._click_locator(loc, f"name: {name[:80]}")
            if ok:
                return True, detail

        if selector:
            ok, detail = await self._click_locator(page.locator(selector).first, f"selector: {selector[:80]}")
            if ok:
                return True, detail

        return False, "Click needs selector, text, or name"

    async def _click_by_text(self, page: Page, text: str) -> tuple[bool, str]:
        if not text:
            return False, "Empty click text"

        pattern = re.compile(re.escape(text), re.I)
        strategies: list[Callable[[], Locator]] = [
            lambda: page.get_by_role("button", name=pattern),
            lambda: page.get_by_role("link", name=pattern),
            lambda: page.get_by_role("tab", name=pattern),
            lambda: page.get_by_role("menuitem", name=pattern),
            lambda: page.get_by_label(pattern),
            lambda: page.locator(
                "button, a, [role='button'], [role='link'], input[type='submit'], input[type='button']"
            ).filter(has_text=pattern),
            lambda: page.get_by_text(text, exact=True),
            lambda: page.get_by_text(text, exact=False),
        ]

        for factory in strategies:
            loc = factory().first
            try:
                if await loc.count() == 0:
                    continue
                ok, detail = await self._click_locator(loc, f"text: {text[:80]}")
                if ok:
                    return True, detail
            except Exception:
                continue

        # DOM fallback — same algorithm as BrowserToolExecutor / observation
        try:
            clicked = await page.evaluate(CLICK_BY_TEXT_JS, text)
            if clicked:
                await asyncio.sleep(0.25)
                return True, f"Clicked: {clicked}"
        except Exception:
            pass

        return False, f"No element matching text: {text[:80]}"

    async def _click_by_role(self, page: Page, role: str, name: str) -> tuple[bool, str]:
        if not role:
            return False, "Empty role"
        pattern = re.compile(re.escape(name), re.I) if name else None
        try:
            loc = page.get_by_role(role, name=pattern).first if pattern else page.get_by_role(role).first
            if await loc.count() == 0:
                return False, f"No role={role}"
            return await self._click_locator(loc, f"role={role} name={name[:40]}")
        except Exception as exc:
            return False, str(exc)[:120]

    async def _click_locator(self, loc: Locator, label: str) -> tuple[bool, str]:
        try:
            await loc.wait_for(state="visible", timeout=5_000)
            await loc.scroll_into_view_if_needed(timeout=5_000)
            await loc.click(timeout=8_000)
            await asyncio.sleep(0.25)
            return True, f"Clicked {label}"
        except Exception:
            return False, f"Failed {label}"

    async def _resolve_input(self, page: Page, action: dict[str, Any]) -> Locator:
        selector = (action.get("selector") or "").strip()
        name = (action.get("name") or "").strip()
        text = (action.get("text") or "").strip()

        if selector:
            loc = page.locator(selector).first
            if await loc.count() > 0:
                return loc

        if name:
            loc = page.locator(
                f'input[name="{name}"], textarea[name="{name}"], #{name}, '
                f'[aria-label*="{name}" i], [placeholder*="{name}" i]'
            ).first
            if await loc.count() > 0:
                return loc

        if text:
            loc = page.get_by_label(re.compile(re.escape(text), re.I)).first
            if await loc.count() > 0:
                return loc
            loc = page.get_by_placeholder(re.compile(re.escape(text), re.I)).first
            if await loc.count() > 0:
                return loc

        for factory in (
            lambda: page.get_by_role("combobox"),
            lambda: page.get_by_role("searchbox"),
            lambda: page.locator('input[name="search_query"]'),
            lambda: page.locator('input[name="q"]'),
            lambda: page.locator('input[type="search"]'),
            lambda: page.locator("textarea"),
            lambda: page.locator('input:not([type="hidden"])'),
        ):
            loc = factory().first
            if await loc.count() > 0:
                return loc

        return page.locator("input").first

    async def _type(self, page: Page, action: dict[str, Any]) -> tuple[bool, str]:
        value = (action.get("value") or "").strip()
        if not value:
            # Recording may put query in "text" for type actions
            value = (action.get("text") or "").strip()
        if not value:
            return False, "Empty type value"

        submit = bool(action.get("submit"))
        loc = await self._resolve_input(page, action)

        await loc.wait_for(state="visible", timeout=8_000)
        await loc.scroll_into_view_if_needed(timeout=5_000)
        await loc.click(timeout=5_000)
        await asyncio.sleep(0.1)

        # Real keystrokes — fill() alone fails on YouTube/Google/React inputs
        try:
            await loc.fill("")
        except Exception:
            await page.keyboard.press("Meta+A")
            await page.keyboard.press("Backspace")

        await loc.press_sequentially(value, delay=35)
        await asyncio.sleep(0.2)

        typed = ""
        try:
            typed = await loc.input_value()
        except Exception:
            pass

        if submit or not typed:
            await page.keyboard.press("Enter")
            await asyncio.sleep(0.5)

        return True, f"Typed: {value[:60]}"
