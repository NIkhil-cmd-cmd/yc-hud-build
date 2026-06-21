# OpenHive Browser

Native macOS browser that learns from you. Forked from [Nook](https://github.com/nook-browser/Nook) (GPL-3.0) with a Python policy engine for passive workflow learning and zero-token replay.

**Hackathon:** HUD Frontier · OpenHive v2

## Architecture

- **Swift UI:** Nook fork — sidebar-first browser, Liquid Glass (macOS 26 Tahoe)
- **Python engine:** `python/engine.py` — observation, MDP training, execution, token metrics
- **Bridge:** WebSocket on `localhost:8765`

## Quick start

### 1. Python engine

```bash
cd python
python3 -m venv ../.venv
source ../.venv/bin/activate
pip install -e ..  # or: pip install websockets openai networkx pydantic
cp ../.env.example ../.env   # fill in API keys
python engine.py
```

### 2. Nook / OpenHive app

```bash
open Nook.xcodeproj
```

Set your Development Team in Signing. Build and run (macOS 15.5+; macOS 26 for full Liquid Glass).

**Note:** Add new Swift files to the Xcode target if not already included:
- `Nook/Managers/EngineBridge/EngineBridge.swift`
- `Nook/Managers/TokenDashboardManager/TokenDashboardManager.swift`
- `Nook/Components/TokensPanel/TokensPanelView.swift`

On launch, `EngineBridge.shared.connect()` should be wired from app init (TODO).

### 3. Passive learning flow

1. Browse normally — engine captures actions silently
2. Sidebar chat: "save this as book flight" — compiles workflow locally
3. Run workflow — 0 tokens when policy matches (T1)

## Docs

- [BUILD_PLAN.md](docs/BUILD_PLAN.md) — full technical plan
- [NOTICES.md](NOTICES.md) — third-party licenses (Nook GPL-3.0)

## Local data

```
~/Library/Application Support/OpenHive/
├── harvest/      # session step logs
├── workflows/    # compiled policies
└── metrics/      # tokens.json, run logs
```

## License

OpenHive engine and additions: GPL-3.0 (same as Nook base). See [LICENSE](LICENSE) and [NOTICES.md](NOTICES.md).
