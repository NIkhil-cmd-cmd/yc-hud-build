"""Exa search and page schema lookups."""

from __future__ import annotations

import os


async def exa_answer(query: str) -> str:
    api_key = os.environ.get("EXA_API_KEY")
    if not api_key:
        return ""
    try:
        from exa_py import Exa

        exa = Exa(api_key)
        result = exa.answer(query, text=True)
        return getattr(result, "answer", str(result))
    except Exception:
        return ""


async def get_page_schema(url: str) -> str:
    """Real-time page schema for Tier 2 unknown states."""
    if not url or url.startswith("about:"):
        return ""
    domain = url.split("/")[2] if "://" in url else url
    return await exa_answer(
        f"What interactive elements and forms exist on {domain}? "
        f"List buttons, inputs, and checkout steps briefly."
    )
