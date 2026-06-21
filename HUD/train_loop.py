#!/usr/bin/env python3
"""Reference training loop — NOT connected to OpenHive engine or Nook.

Prerequisites:
  1. `hud models fork claude-haiku-4-5 --name my-openhive-agent`
  2. `hud deploy HUD` and `hud sync openhive-browser-tasks HUD/env.py`
  3. HUD_API_KEY in repo root .env

Run (after deploy):
  python HUD/train_loop.py --model my-openhive-agent --taskset openhive-browser-tasks --steps 3 --group 4

This script is a skeleton: it shows how TrainingClient + Taskset.run() fit together.
Uncomment and adapt once you have a deployed taskset and forked trainable model.
"""

from __future__ import annotations

import argparse
import asyncio

from config import HUDConnection, load_settings

# from hud import Job, Taskset
# from hud.agents import create_agent
# from hud.train import TrainingClient


async def training_skeleton(
    *,
    model: str,
    taskset: str,
    steps: int,
    group: int,
    learning_rate: float,
) -> None:
    conn = HUDConnection.from_settings(load_settings())
    print(f"Training target model: {model}")
    print(f"Taskset: {taskset} | steps={steps} group={group} lr={learning_rate}")
    print(f"RL service: {conn.rl_url}")
    print()
    print("Skeleton only — wire up when ready:")
    print("  agent = create_agent(model, completion_kwargs={'extra_body': {'return_token_ids': True}})")
    print("  trainer = TrainingClient(model)")
    print("  taskset = Taskset.from_api(taskset)")
    print("  session = await Job.start(model, group=group)")
    print("  for _ in range(steps):")
    print("      start = len(session.runs)")
    print("      await taskset.run(agent, job=session)")
    print("      await trainer.step(session.runs[start:], learning_rate=learning_rate, group_size=group)")
    print()
    print("Inspect progress: hud models checkpoints", model)


def main() -> None:
    parser = argparse.ArgumentParser(description="HUD training loop skeleton")
    parser.add_argument("--model", required=True, help="Forked trainable model slug")
    parser.add_argument("--taskset", default="openhive-browser-tasks")
    parser.add_argument("--steps", type=int, default=5)
    parser.add_argument("--group", type=int, default=8, help="GRPO group size (within-group reward spread)")
    parser.add_argument("--lr", type=float, default=1e-5)
    args = parser.parse_args()
    asyncio.run(
        training_skeleton(
            model=args.model,
            taskset=args.taskset,
            steps=args.steps,
            group=args.group,
            learning_rate=args.lr,
        )
    )


if __name__ == "__main__":
    main()
