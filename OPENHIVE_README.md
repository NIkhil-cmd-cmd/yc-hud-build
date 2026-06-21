# OpenHive — Nook + Python Policy Engine

**The agent thought once. Now it never has to again.**

OpenHive is a native macOS browser ([Nook](https://github.com/nook-browser/Nook) fork) with a local Python policy engine for passive learning and zero-token workflow replay.

## Quick start

```bash
# 1. Python engine
cd ~/yc && source .venv/bin/activate
pip install -r python/requirements.txt
cp .env.example .env   # optional: Fireworks, OpenAI, Exa keys
./scripts/start_engine.sh   # ws://127.0.0.1:8765

# 2. Nook app (separate terminal)
open Nook.xcodeproj
# Set Development Team in Signing, then Run
```

Or one command for the engine only:

```bash
./scripts/start_nook.sh
```

## Usage

1. Browse in Nook — actions recorded passively in the background
2. Ask the AI sidebar to complete a task, or browse manually
3. Save as workflow (`Cmd+Shift+S` or chat: "save this as …")
4. Run again — policy replay uses 0 LLM tokens when state matches

## Architecture

- **Nook Swift UI** — WKWebView tabs, AI sidebar, workflow list
- **EngineBridge** — WebSocket client to `python/engine.py`
- **Python** — `engine.py`, `observer.py`, `train.py`, `executor.py`, `collector.py`
- **Playwright** — optional batch trace collection (`python -m collector`)

Full build plan: [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md)

## Batch trace collection (Playwright)

```bash
source .venv/bin/activate
cd python
python collector.py --gate --limit 3      # local-browser-gate smoke
python collector.py --gate --limit 20     # batch local
python datagen/modal_collect.py           # parallel via Modal (local fallback)
```

Artifacts: `artifacts/local-browser-gate/<run_id>/` (trace JSONL, DOM, a11y, screenshots, `policy.json`).
