"""Standalone HUD v6 environment for browser-agent training (not wired to OpenHive yet).

Local iteration:
    cd HUD && hud eval env.py claude-haiku-4-5 --max-steps 20

Deploy + sync (when ready):
    hud deploy HUD
    hud sync openhive-browser-tasks HUD/env.py
"""

from __future__ import annotations

from pydantic import BaseModel

from hud.environment import Environment

env = Environment(name="openhive-browser-training")

# Browser CDP is injected by the HUD runtime during `hud eval --runtime hud` or
# platform deploy — do not declare a static CDP URL here.
# For shell/file tasks during local iteration, uncomment:
# ws = env.workspace("/tmp/openhive-hud-workspace", network=True)


class FlightParams(BaseModel):
    origin: str
    destination: str
    date: str


@env.template(id="book_flight")
async def book_flight(origin: str = "BOS", destination: str = "SFO", date: str = "2026-07-15"):
    """Multi-step flight search — agent uses browser CDP tools, grader checks outcome."""
    prompt = (
        f"On Google Flights, search a one-way flight from {origin} to {destination} "
        f"departing {date}. Stop when flight results with prices are visible."
    )
    answer = yield prompt
    # Placeholder grader: swap for combine() + BashGrader / LLMJudge once substrate is stable.
    haystack = (answer or "").lower()
    route_ok = origin.lower() in haystack and destination.lower() in haystack
    results_ok = any(m in haystack for m in ("flights/search", "departing flights", "price"))
    yield 1.0 if route_ok and results_ok else (0.5 if route_ok else 0.0)


@env.template(id="smoke_ping")
async def smoke_ping(word: str = "openhive"):
    """Tiny task for verifying env wiring without a browser."""
    answer = yield f"Reply with exactly: pong-{word}"
    yield 1.0 if answer and f"pong-{word}" in str(answer) else 0.0


# Taskset entry points for `hud eval env.py`
tasks = [
    smoke_ping(),
    book_flight(origin="BOS", destination="SFO", date="2026-07-15"),
]
