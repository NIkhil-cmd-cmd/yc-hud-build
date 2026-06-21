"""Train flight booking MDP policy from collected trajectories.

Takes the proven multi-step traces from run_local_browser_trace_gate.py
and builds a Markov Decision Process policy using:
- State clustering (cosine similarity θ=0.88)
- Value iteration (γ=0.95)
- Action aggregation

Output: A workflow.json that can be executed via PolicyExecutor
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import sys
import networkx as nx

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from embeddings import cosine
from openai import OpenAI

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = ROOT / "artifacts" / "local-browser-gate"
WORKFLOW_DIR = Path.home() / "Library/Application Support/OpenHive/workflows"

# MDP hyperparameters (from BUILD_PLAN.md)
THETA_STATE = 0.88  # State clustering threshold
GAMMA = 0.95  # Discount factor for value iteration
MAX_ITER = 50  # Max iterations for value iteration


def load_trajectories(run_dir: Path) -> list[dict[str, Any]]:
    """Load all successful trajectory traces from a gate run."""

    # Try loading from all_traces.jsonl first (contains all steps from all runs)
    all_traces_file = run_dir / "all_traces.jsonl"
    if all_traces_file.exists():
        print(f"  Loading from all_traces.jsonl...")
        all_steps = []
        for line in all_traces_file.read_text().splitlines():
            if line.strip():
                all_steps.append(json.loads(line))

        # Group steps by task
        from collections import defaultdict
        by_task = defaultdict(list)
        for step in all_steps:
            task = step.get("task", {})
            key = f"{task.get('origin')}_{task.get('destination')}_{task.get('departDate')}"
            by_task[key].append(step)

        # Create trace per task
        traces = []
        for key, steps in by_task.items():
            if steps:
                task = steps[0].get("task", {})
                url = steps[-1].get("url", "")
                traces.append({
                    "task": task,
                    "steps": steps,
                    "url": url,
                })
        return traces

    # Fallback: Load from individual trace files
    traces = []
    report_path = run_dir / "report.json"
    if not report_path.exists():
        print(f"No report.json or all_traces.jsonl in {run_dir}")
        return []

    report = json.loads(report_path.read_text())

    # Load each successful trace
    for run in report.get("runs", []):
        if not run.get("ok"):
            continue

        trace_dir = ROOT / run["dir"]
        trace_file = trace_dir / "trace.jsonl"

        if not trace_file.exists():
            continue

        # Parse JSONL
        steps = []
        for line in trace_file.read_text().splitlines():
            if line.strip():
                steps.append(json.loads(line))

        if steps:
            traces.append({
                "task": run["task"],
                "steps": steps,
                "url": run["url"],
            })

    return traces


def build_mdp_graph(traces: list[dict]) -> nx.DiGraph:
    """
    Build MDP graph from trajectories.

    Clusters states by:
    - URL pattern (host + path)
    - State embedding (cosine similarity >= θ)

    Aggregates transitions with success counts.
    """
    G = nx.DiGraph()
    centroids: list[tuple[int, list[float], str]] = []

    print(f"\nBuilding MDP graph from {len(traces)} trajectories...")

    for trace_idx, trace in enumerate(traces):
        steps = trace["steps"]
        prev_node_id: int | None = None

        print(f"  Trace {trace_idx + 1}: {trace['task']['origin']} → {trace['task']['destination']} ({len(steps)} steps)")

        for step_idx, step in enumerate(steps):
            # Extract state
            state_emb = step.get("stateEmbedding", [])
            url = step.get("url", "")

            if not state_emb or not url:
                continue

            # Find or create node
            node_id = match_or_create_node(centroids, state_emb, url)

            # Add node if new
            if node_id not in G:
                G.add_node(
                    node_id,
                    state_emb=state_emb,
                    url=url,
                    url_pattern=url_pattern(url),
                    visits=0,
                )

            # Increment visit count
            G.nodes[node_id]["visits"] += 1

            # Add edge from previous state
            if prev_node_id is not None:
                action = step.get("action", {})

                if G.has_edge(prev_node_id, node_id):
                    # Increment success count
                    G[prev_node_id][node_id]["successes"] += 1
                else:
                    # New edge
                    G.add_edge(
                        prev_node_id,
                        node_id,
                        action=action,
                        successes=1,
                    )

            prev_node_id = node_id

        # Mark final state
        if prev_node_id is not None:
            G.nodes[prev_node_id]["terminal"] = True

    print(f"\n  Graph: {len(G.nodes())} states, {len(G.edges())} transitions")
    return G


def match_or_create_node(
    centroids: list[tuple[int, list[float], str]],
    emb: list[float],
    url: str,
) -> int:
    """Find existing node with similar state or create new one."""
    pattern = url_pattern(url)

    # Try to match existing centroid
    for node_id, centroid, pat in centroids:
        if pat == pattern and cosine(emb, centroid) >= THETA_STATE:
            # Update centroid (running average)
            # For simplicity, just return the ID
            # In production, you'd update the centroid
            return node_id

    # Create new centroid
    new_id = len(centroids)
    centroids.append((new_id, emb, pattern))
    return new_id


def url_pattern(url: str) -> str:
    """Extract URL pattern (host + path, no query params)."""
    from urllib.parse import urlparse

    p = urlparse(url)
    return f"{p.netloc}{p.path.rstrip('/')}"


def value_iteration(G: nx.DiGraph) -> tuple[dict[int, float], dict[int, dict]]:
    """
    Run value iteration to compute optimal policy.

    Returns:
        (values, policy) where policy[state] = {next: next_state, action: action_dict}
    """
    if not G.nodes():
        return {}, {}

    nodes = list(G.nodes())
    V = {n: 0.0 for n in nodes}

    print(f"\nRunning value iteration (γ={GAMMA})...")

    for iteration in range(MAX_ITER):
        delta = 0.0

        for n in nodes:
            if G.nodes[n].get("terminal"):
                # Terminal state has value 1.0
                V[n] = 1.0
                continue

            old_v = V[n]

            # Compute Q-values for all actions
            best_q = 0.0
            for _, succ, data in G.out_edges(n, data=True):
                # Reward = 1.0 for reaching successor
                # (In production, could use success rate)
                reward = 1.0
                q = reward + GAMMA * V[succ]
                best_q = max(best_q, q)

            V[n] = best_q
            delta = max(delta, abs(old_v - V[n]))

        if iteration % 10 == 0:
            print(f"  Iteration {iteration}: δ={delta:.6f}")

        if delta < 1e-4:
            print(f"  Converged at iteration {iteration}")
            break

    # Extract policy
    policy: dict[int, dict] = {}
    for n in nodes:
        if G.nodes[n].get("terminal"):
            continue

        best_succ = None
        best_q = -1.0
        best_action = {}

        for _, succ, data in G.out_edges(n, data=True):
            reward = 1.0
            q = reward + GAMMA * V[succ]

            if q > best_q:
                best_q = q
                best_succ = succ
                best_action = data.get("action", {})

        if best_succ is not None:
            policy[n] = {
                "next": best_succ,
                "action": best_action,
                "value": V[n],
            }

    return V, policy


def extract_action_sequence(traces: list[dict]) -> list[dict]:
    """
    Extract linear action sequence from successful trajectories.

    This is used for Tier 1 replay execution (no graph lookup needed).
    """
    # Use the first successful trace as the canonical sequence
    if not traces:
        return []

    first_trace = traces[0]
    actions = []

    for step in first_trace["steps"]:
        action = step.get("action", {})
        action_type = action.get("type")

        # Filter to executable actions
        if action_type in {"click", "type", "click_iso_date", "click_xy", "next_month", "navigate"}:
            actions.append(action)

    return actions


def save_workflow(
    G: nx.DiGraph,
    policy: dict[int, dict],
    values: dict[int, float],
    action_sequence: list[dict],
    traces: list[dict],
    name: str,
    output_path: Path,
) -> dict:
    """Save trained policy as workflow JSON."""

    # Convert nodes to serializable format
    nodes = {}
    for node_id in G.nodes():
        node = dict(G.nodes[node_id])
        nodes[str(node_id)] = {
            "state_emb": node.get("state_emb", []),
            "url": node.get("url", ""),
            "url_pattern": node.get("url_pattern", ""),
            "visits": node.get("visits", 0),
            "terminal": node.get("terminal", False),
            "value": values.get(node_id, 0.0),
        }

    # Convert policy to serializable format
    policy_dict = {}
    for state_id, entry in policy.items():
        policy_dict[str(state_id)] = {
            "next": str(entry["next"]),
            "action": entry["action"],
            "value": entry.get("value", 0.0),
        }

    # Find start node (lowest ID)
    start_node = str(min(G.nodes())) if G.nodes() else "0"

    workflow = {
        "id": f"flight_booking_{int(time.time())}",
        "name": name,
        "policy": policy_dict,
        "nodes": nodes,
        "actions": action_sequence,  # For Tier 1 replay
        "steps": len(action_sequence),
        "startNode": start_node,
        "metadata": {
            "trainer": "train_flight_policy",
            "theta": THETA_STATE,
            "gamma": GAMMA,
            "nodeCount": len(nodes),
            "edgeCount": len(G.edges()),
            "traceCount": len(traces),
        },
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(workflow, indent=2))

    print(f"\n✓ Saved workflow to {output_path}")
    print(f"  Nodes: {len(nodes)}")
    print(f"  Policy states: {len(policy_dict)}")
    print(f"  Action sequence: {len(action_sequence)} steps")

    return workflow


def main():
    parser = argparse.ArgumentParser(
        description="Train flight booking MDP policy from traces"
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        help="Path to gate run directory (e.g., artifacts/local-browser-gate/gate_20260620_212645)",
    )
    parser.add_argument(
        "--name",
        default="Flight Booking (Google Flights)",
        help="Workflow name",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output path for workflow.json (default: OpenHive workflows dir)",
    )
    args = parser.parse_args()

    # Find latest gate run if not specified
    if not args.run_dir:
        gate_runs = sorted(ARTIFACT_ROOT.glob("gate_*"))
        if not gate_runs:
            print("No gate runs found in artifacts/local-browser-gate/")
            print("Run: python python/smoke/run_local_browser_trace_gate.py --limit 3")
            return 1
        args.run_dir = gate_runs[-1]

    # Convert to absolute path
    args.run_dir = args.run_dir.resolve()

    if not args.run_dir.exists():
        print(f"Run directory not found: {args.run_dir}")
        return 1

    try:
        rel_path = args.run_dir.relative_to(ROOT)
        print(f"Training from: {rel_path}")
    except ValueError:
        print(f"Training from: {args.run_dir}")

    # Load trajectories
    traces = load_trajectories(args.run_dir)
    if not traces:
        print("No successful trajectories found")
        return 1

    print(f"Loaded {len(traces)} successful trajectories")

    # Build MDP graph
    G = build_mdp_graph(traces)

    # Run value iteration
    values, policy = value_iteration(G)

    # Extract action sequence for Tier 1 replay
    action_sequence = extract_action_sequence(traces)

    # Save workflow
    if not args.output:
        WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
        args.output = WORKFLOW_DIR / f"flight_booking_{int(time.time())}.json"

    workflow = save_workflow(
        G,
        policy,
        values,
        action_sequence,
        traces,
        args.name,
        args.output,
    )

    # Print summary
    print("\n" + "="*60)
    print("MDP Training Complete")
    print("="*60)
    print(f"Workflow ID: {workflow['id']}")
    print(f"Name: {workflow['name']}")
    print(f"States: {len(workflow['nodes'])}")
    print(f"Transitions: {workflow['metadata']['edgeCount']}")
    print(f"Action sequence: {len(workflow['actions'])} steps")
    try:
        output_rel = args.output.relative_to(ROOT)
        print(f"\nOutput: {output_rel}")
    except ValueError:
        print(f"\nOutput: {args.output}")
    print("\nTo execute:")
    print(f"  # In OpenHive app: Run workflow '{args.name}'")
    print(f"  # Or via Python: PolicyExecutor(workflow, params={{'origin': 'SFO', 'destination': 'NYC'}})")

    return 0


if __name__ == "__main__":
    exit(main())
