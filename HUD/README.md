# HUD training workspace

Self-contained [HUD v6](https://docs.hud.ai) environment for **eval and RL training**. This folder is intentionally **not wired** to the OpenHive engine, Nook `EngineBridge`, or `python/hud_grade.py` yet.

## What lives here

| File | Purpose |
|------|---------|
| `env.py` | v6 `Environment` + task templates (`smoke_ping`, `book_flight`) |
| `connect.py` | Verify API key, gateway, RL service, local grader wiring |
| `train_loop.py` | Reference training skeleton (`TrainingClient` + `Taskset`) |
| `config.py` | Load `HUD_API_KEY` from repo root `.env` |
| `Dockerfile` | For `hud deploy HUD` when you push to the platform |

Related code elsewhere (unchanged):

- `python/hud_env.py` — grading templates used by live Nook runs
- `python/hud_grade.py` — grades completed WKWebView executions
- `python/benchmark/hud_browser_compare.py` — native vs HUD browser benchmark

## Prerequisites

```bash
# From repo root (shared venv already has hud-python)
source .venv/bin/activate
pip install -r HUD/requirements.txt

# API key in repo root .env (see HUD/.env.example)
HUD_API_KEY=sk-hud-...
```

Or: `hud login` / `hud set HUD_API_KEY ...` (writes `~/.hud/.env`).

## Connection map

HUD splits across a few endpoints (all configured in `hud.settings`):

| Service | Default URL | Used for |
|---------|-------------|----------|
| Platform API | `https://api.beta.hud.ai` | deploy, tasksets, model resolve |
| Inference gateway | `https://inference.beta.hud.ai` | agent rollouts (`create_agent`) |
| RL / training | `https://rl.beta.hud.ai` | `TrainingClient.step()` |
| Runtime tunnel | `https://mcp.beta.hud.ai` | remote env capabilities (`--runtime hud`) |

### Verify connectivity

```bash
./HUD/scripts/verify_connection.sh
# or
cd HUD && python connect.py --json
```

Expected: API ok, gateway ok, local `smoke_ping` grader returns reward 1.0.

## Local eval (no deploy)

```bash
./HUD/scripts/local_eval.sh claude-haiku-4-5
# equivalent:
cd HUD && hud eval env.py claude-haiku-4-5 --max-steps 20
```

`smoke_ping` runs without a browser. `book_flight` uses the CDP capability and needs the agent to drive a real browser sandbox.

## Platform deploy + taskset sync

When you're ready to run at scale or train:

```bash
cd HUD
hud deploy .                    # builds Dockerfile, links .hud/deploy.json
hud sync openhive-browser-tasks env.py   # upload tasks to platform taskset
hud eval openhive-browser-tasks claude-haiku-4-5 --remote --full
```

## Training path (not wired yet)

1. **Fork a trainable model**
   ```bash
   hud models fork claude-haiku-4-5 --name my-openhive-agent
   hud models list   # confirm Trainable column
   ```

2. **Roll out with token IDs** (required for gradients)
   ```python
   from hud.agents import create_agent
   agent = create_agent("my-openhive-agent", completion_kwargs={"extra_body": {"return_token_ids": True}})
   ```

3. **GRPO training loop** — see `train_loop.py` and [HUD training docs](https://docs.hud.ai/v6/core/training):
   ```python
   from hud import Job, Taskset
   from hud.train import TrainingClient

   trainer = TrainingClient("my-openhive-agent")
   taskset = Taskset.from_api("openhive-browser-tasks")
   session = await Job.start("my-openhive-agent", group=8)
   await taskset.run(agent, job=session)
   await trainer.step(session.runs, learning_rate=1e-5, group_size=8)
   ```

4. **Inspect rollouts**
   ```bash
   hud jobs
   hud trace <trace-id>
   ```

## Wiring to OpenHive (future)

When you connect this to Nook:

- **Eval**: route completed trajectories from `python/trajectory_runner.py` into `HUD/env.py` graders (or replace `python/hud_grade.py` imports to use `HUD/env.py`).
- **Train**: export token-level traces from agent runs with `return_token_ids`, feed `TrainingClient.step()`.
- **Browser**: Nook WKWebView (in-tab) vs HUD CDP sandbox (RL rollouts) are different substrates — pick one per task or bridge via MCP.

Do not merge until task quality checks pass (multi-step, reward spread within group, no answer leakage). See `.agents/skills/hud-environment-builder/SKILL.md`.
