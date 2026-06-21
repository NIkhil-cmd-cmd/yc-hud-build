"""HUD environment — flight booking task + LLMJudgeGrader."""

from __future__ import annotations

from pydantic import BaseModel

from hud.environment import Environment
from hud.graders import LLMJudgeGrader, combine

env = Environment(name="openhive-browser")


class FlightParams(BaseModel):
    origin: str
    destination: str
    date: str


@env.template(id="book_flight")
async def book_flight(params: FlightParams):
    prompt = (
        f"Book cheapest one-way flight {params.origin} to {params.destination} "
        f"on {params.date}. Stop when price is visible on airline checkout."
    )
    answer = yield prompt
    yield await combine(
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=[f"Flight route matches {params.origin} to {params.destination}"],
            question=prompt,
        ),
        LLMJudgeGrader.grade(
            weight=0.25,
            answer=answer,
            criteria=[f"Date matches {params.date}"],
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
