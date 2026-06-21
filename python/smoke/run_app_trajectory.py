"""Run proven multi-step trajectories in the Swift OpenHive app (not Playwright).

Takes the scripted_action logic from run_local_browser_trace_gate.py that passed
20/20 smoke tests and drives it through the Swift app's WKWebView via WebSocket.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path

import websockets
from websockets.client import WebSocketClientProtocol

# Import proven logic from local smoke
from run_local_browser_trace_gate import (
    scripted_action,
    reached_results,
    TASK_MATRIX,
)

logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(asctime)s | %(message)s",
)
logger = logging.getLogger("app_trajectory")

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = ROOT / "artifacts" / "app-trajectories"


class AppTrajectoryRunner:
    """
    Runs multi-step flight booking trajectories in the Swift app.

    Uses the same proven scripted_action logic that passed 20/20 local smoke tests.
    """

    def __init__(self, ws_url: str = "ws://localhost:8765"):
        self.ws_url = ws_url
        self.ws: WebSocketClientProtocol | None = None
        self.state_received = asyncio.Event()
        self.last_state: dict | None = None

    async def connect(self):
        """Connect to the Swift app's engine bridge."""
        logger.info(f"Connecting to Swift app at {self.ws_url}")
        self.ws = await websockets.connect(self.ws_url)
        logger.info("✓ Connected")

        # Start receiving messages
        asyncio.create_task(self.receive_loop())

    async def receive_loop(self):
        """Receive messages from Swift app."""
        try:
            async for message in self.ws:
                data = json.loads(message)
                await self.handle_message(data)
        except websockets.exceptions.ConnectionClosed:
            logger.warning("Connection closed")
        except Exception as e:
            logger.error(f"Receive error: {e}")

    async def handle_message(self, msg: dict):
        """Handle incoming messages from Swift."""
        msg_type = msg.get("type")

        if msg_type == "state":
            # Swift sent page state
            self.last_state = msg
            self.state_received.set()

        elif msg_type == "step_complete":
            step = msg.get("step", {})
            logger.info(f"  ✓ Step {step.get('index')}: {step.get('url', '')[:60]}")

        elif msg_type == "trajectory_complete":
            success = msg.get("success", False)
            steps = msg.get("steps", 0)
            final_url = msg.get("finalUrl", "")
            reason = msg.get("reason", "")

            logger.info(
                f"{'✓' if success else '✗'} Trajectory complete: {steps} steps, {reason}"
            )
            logger.info(f"  Final URL: {final_url[:80]}")

        elif msg_type == "error":
            logger.error(f"✗ Error: {msg.get('error')}")

    async def send_action(self, action: dict):
        """Send action to Swift for execution."""
        await self.ws.send(json.dumps({"type": "action", "action": action}))

    async def request_state(self):
        """Request current page state from Swift."""
        self.state_received.clear()
        await self.ws.send(json.dumps({"type": "request_state"}))

    async def run_trajectory(self, task: dict, max_steps: int = 10) -> dict:
        """
        Run one multi-step trajectory using the proven scripted_action logic.

        Returns:
            dict with success, steps, finalUrl, etc.
        """
        origin = task["origin"]
        destination = task["destination"]
        date = task["departDate"]

        logger.info(f"\n{'='*60}")
        logger.info(f"Starting: {origin} → {destination} on {date}")
        logger.info(f"{'='*60}")

        artifact_dir = ARTIFACT_ROOT / f"trace_{origin}_{destination}_{int(time.time())}"
        artifact_dir.mkdir(parents=True, exist_ok=True)

        history = []
        steps_log = []
        t0 = time.time()

        try:
            # Step 0: Navigate to Google Flights
            logger.info("→ Navigating to Google Flights")
            await self.send_action(
                {
                    "type": "navigate",
                    "url": "https://www.google.com/travel/flights",
                    "ref": None,
                    "value": None,
                }
            )

            # Wait for page load
            await asyncio.sleep(5)

            # Get initial state
            logger.info("→ Getting initial state")
            await self.request_state()
            await asyncio.wait_for(self.state_received.wait(), timeout=10)
            self.state_received.clear()

            # Multi-step loop (same as local smoke)
            for step in range(max_steps):
                state = self.last_state
                candidates = state.get("candidates", [])

                logger.info(
                    f"\nStep {step}: {len(candidates)} candidates on {state.get('url', '')[:50]}"
                )

                # Check if we've reached results
                summary = {
                    "url": state.get("url", ""),
                    "title": state.get("title", ""),
                    "text": state.get("text", ""),
                }

                if step > 0 and reached_results(summary):
                    logger.info(f"✓ Results detected at step {step}")
                    elapsed = time.time() - t0
                    result = {
                        "success": True,
                        "steps": step,
                        "finalUrl": state["url"],
                        "elapsedSec": round(elapsed, 1),
                        "reason": "results_detected",
                        "trajectory": steps_log,
                    }
                    (artifact_dir / "report.json").write_text(
                        json.dumps(result, indent=2)
                    )
                    return result

                # Get next action from proven scripted expert
                action = scripted_action(task, candidates, history)

                action_desc = f"{action.get('action')} {action.get('value') or ''}"
                logger.info(f"  → {action_desc}")

                # Send action to Swift
                await self.send_action(action)

                # Wait for state update (with timeout)
                await asyncio.wait_for(self.state_received.wait(), timeout=15)
                self.state_received.clear()

                # Log step
                new_state = self.last_state
                step_entry = {
                    "step": step,
                    "action": action,
                    "url": new_state.get("url", ""),
                    "candidateCount": len(candidates),
                }
                history.append(step_entry)
                steps_log.append(step_entry)

                # Check again after action
                new_summary = {
                    "url": new_state.get("url", ""),
                    "title": new_state.get("title", ""),
                    "text": new_state.get("text", ""),
                }
                if reached_results(new_summary):
                    logger.info(f"✓ Results detected after step {step}")
                    elapsed = time.time() - t0
                    result = {
                        "success": True,
                        "steps": step + 1,
                        "finalUrl": new_state["url"],
                        "elapsedSec": round(elapsed, 1),
                        "reason": "results_detected",
                        "trajectory": steps_log,
                    }
                    (artifact_dir / "report.json").write_text(
                        json.dumps(result, indent=2)
                    )
                    return result

            # Max steps reached
            logger.warning(f"✗ Max steps ({max_steps}) reached without results")
            elapsed = time.time() - t0
            result = {
                "success": False,
                "steps": max_steps,
                "finalUrl": self.last_state.get("url", ""),
                "elapsedSec": round(elapsed, 1),
                "reason": "max_steps",
                "trajectory": steps_log,
            }
            (artifact_dir / "report.json").write_text(json.dumps(result, indent=2))
            return result

        except asyncio.TimeoutError:
            logger.error("✗ Timeout waiting for state")
            return {
                "success": False,
                "error": "Timeout waiting for browser state",
                "steps": len(steps_log),
            }
        except Exception as e:
            logger.error(f"✗ Trajectory failed: {e}", exc_info=True)
            return {"success": False, "error": str(e), "steps": len(steps_log)}


async def main():
    """Run the 3-task smoke suite in the Swift app."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run multi-step trajectories in Swift app"
    )
    parser.add_argument(
        "--limit", type=int, default=3, help="Number of tasks to run"
    )
    parser.add_argument(
        "--offset", type=int, default=0, help="Offset into TASK_MATRIX"
    )
    parser.add_argument(
        "--max-steps", type=int, default=10, help="Max steps per trajectory"
    )
    args = parser.parse_args()

    # Build task list
    tasks = [
        {
            "origin": origin,
            "destination": destination,
            "departDate": depart_date,
        }
        for origin, destination, depart_date in TASK_MATRIX[
            args.offset : args.offset + args.limit
        ]
    ]

    logger.info(f"\n{'='*60}")
    logger.info("OpenHive App Trajectory Smoke Test")
    logger.info(f"{'='*60}")
    logger.info(f"Tasks: {len(tasks)}")
    logger.info(f"Max steps: {args.max_steps}")
    logger.info(f"\n")

    # Wait for user to start app
    input("Start the OpenHive app and connect EngineBridge, then press Enter...")

    # Connect to app
    runner = AppTrajectoryRunner()
    await runner.connect()

    # Run trajectories
    results = []
    for i, task in enumerate(tasks):
        logger.info(f"\n\nTask {i+1}/{len(tasks)}")
        result = await runner.run_trajectory(task, max_steps=args.max_steps)
        results.append(result)

        # Brief pause between tasks
        if i < len(tasks) - 1:
            await asyncio.sleep(2)

    # Summary
    succeeded = sum(1 for r in results if r.get("success"))
    total_steps = sum(r.get("steps", 0) for r in results)

    logger.info(f"\n{'='*60}")
    logger.info("SUMMARY")
    logger.info(f"{'='*60}")
    logger.info(f"Succeeded: {succeeded}/{len(tasks)}")
    logger.info(f"Total steps: {total_steps}")
    logger.info(f"Artifacts: {ARTIFACT_ROOT.relative_to(ROOT)}")

    for i, (task, result) in enumerate(zip(tasks, results)):
        status = "✓" if result.get("success") else "✗"
        steps = result.get("steps", 0)
        elapsed = result.get("elapsedSec", 0)
        logger.info(
            f"  {status} {task['origin']}→{task['destination']}: {steps} steps, {elapsed}s"
        )

    # Write summary
    summary_path = ARTIFACT_ROOT / f"smoke_summary_{int(time.time())}.json"
    summary = {
        "succeeded": succeeded,
        "attempted": len(tasks),
        "totalSteps": total_steps,
        "runs": [
            {
                "task": task,
                "success": result.get("success"),
                "steps": result.get("steps"),
                "elapsedSec": result.get("elapsedSec"),
                "finalUrl": result.get("finalUrl", ""),
            }
            for task, result in zip(tasks, results)
        ],
    }
    summary_path.write_text(json.dumps(summary, indent=2))
    logger.info(f"\nSummary: {summary_path.relative_to(ROOT)}")

    if succeeded == len(tasks):
        logger.info("\n✓✓✓ ALL TASKS PASSED ✓✓✓")
        return 0
    else:
        logger.error(f"\n✗✗✗ {len(tasks) - succeeded} TASKS FAILED ✗✗✗")
        return 1


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    raise SystemExit(exit_code)
