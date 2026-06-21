# OpenHive — HUD Frontier Hackathon

**Tagline:** The agent thought once. Now it never has to again.

OpenHive is a native macOS browser (Nook fork) that passively learns workflows from your browsing, compiles them into embedding-based Markov policies, and replays tasks with zero LLM tokens on Tier 1 execution.

## Quick start

### 1. Python engine (required)

```bash
cd /Users/nikhilkrishnaswamy/yc
source .venv/bin/activate
pip install websockets openai networkx pydantic
cp .env.example .env   # optional API keys
cd python && python engine.py
```

### 2. Xcode

```bash
open Nook.xcodeproj
```

Build and run. On launch, the app connects to `ws://localhost:8765`.

## Usage

1. Browse normally — actions are captured silently
2. In AI sidebar chat: `save this as book cheapest flight` (or `Cmd+Shift+S`)
3. Click **Run** on a saved workflow in the OpenHive panel
4. `Cmd+Shift+T` — tokens dashboard

## Architecture

- **Swift:** Nook fork + EngineBridge + OpenHivePanelView
- **Python:** engine.py, observer, train, executor, hud_env, exa_client, datagen

See [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md).
