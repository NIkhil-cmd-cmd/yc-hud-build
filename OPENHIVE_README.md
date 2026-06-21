# OpenHive — BrowserOS + Python Policy Engine

**The agent thought once. Now it never has to again.**

OpenHive runs on **[BrowserOS](https://github.com/browseros-ai/BrowserOS)** (CDP automation) with a local Python policy engine for passive learning and zero-token replay.

> **Nook is deprecated** for this project direction. See [docs/BROWSEROS.md](docs/BROWSEROS.md).

## Quick start

```bash
# 1. Install BrowserOS app from https://www.browseros.com/

# 2. Python engine
cd ~/yc && source .venv/bin/activate
./scripts/start_engine.sh

# 3. Agent bridge + extension (separate terminal)
./scripts/start_browseros.sh
```

## Usage

1. Browse in BrowserOS — actions recorded passively
2. Side panel → **Workflows** → name → **Save**
3. **Run** replays via real CDP clicks (not WKWebView)

## Architecture

- **BrowserOS agent server** — OpenHive bridge (`BrowserOS/packages/browseros-agent/apps/server/src/lib/clients/openhive/`)
- **BrowserOS extension** — observation content script + workflows panel
- **Python** — `engine.py`, `observer.py`, `train.py`, `executor.py`, `exa_client.py`

Full migration guide: [docs/BROWSEROS.md](docs/BROWSEROS.md)
