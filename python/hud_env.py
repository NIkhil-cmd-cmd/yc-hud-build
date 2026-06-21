"""HUD v6 browser environment — flight booking eval tasks."""

from __future__ import annotations

from pydantic import BaseModel

from hud.environment import Environment
from hud.graders import LLMJudgeGrader, combine

env = Environment(name="openhive-browser")
# Live OpenHive drives WKWebView directly; CDP capability is for full HUD agent rollouts.


class FlightParams(BaseModel):
    origin: str
    destination: str
    date: str


@env.template(id="book_flight")
async def book_flight(origin: str = "SFO", destination: str = "JFK", date: str = "2026-07-15"):
    prompt = (
        f"Book cheapest one-way flight {origin} to {destination} "
        f"on {date}. Stop when price is visible on airline checkout."
    )
    answer = yield prompt
    yield await combine(
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=[f"Flight route matches {origin} to {destination}"],
            question=prompt,
        ),
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=[f"Date matches {date}"],
            question=prompt,
        ),
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=["Flight results or booking page reached"],
            question=prompt,
        ),
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=["Price visible or airline checkout reached"],
            question=prompt,
        ),
    )
