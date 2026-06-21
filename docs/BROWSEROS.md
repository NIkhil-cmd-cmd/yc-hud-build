# OpenHive on BrowserOS

This repo pivots from the Nook/WKWebView shell to **[BrowserOS](https://github.com/browseros-ai/BrowserOS)** for reliable CDP-based automation, while keeping the **OpenHive Python policy engine** (`python/`).

## What moved where

| Nook / OpenHive (before) | BrowserOS (now) |
|--------------------------|-----------------|
| Nook Swift UI + WKWebView | BrowserOS Chromium + agent extension |
| `EngineBridge.swift` WebSocket | `apps/server/src/lib/clients/openhive/bridge.ts` |
| `BrowserToolExecutor` JS clicks | CDP `Runtime.evaluate` in `action-executor.ts` |
| `OpenHiveObservation.swift` | `apps/agent/entrypoints/openhive.content.ts` |
| `OpenHivePanelView` | Side panel → `OpenHiveWorkflowsPanel` |
| Passive record → compile → replay | Same Python engine (`engine.py`) |

## Quick start

### 1. Install BrowserOS

Download the macOS app: [browseros.com](https://www.browseros.com/)

Import Chrome data if you want. Connect an LLM provider in settings (Claude, OpenAI, Ollama, etc.) — this replaces Nook’s AI sidebar for chat.

### 2. Python engine

```bash
cd ~/yc
source .venv/bin/activate
pip install -r requirements.txt  # or: pip install websockets openai networkx pydantic
cp .env.example .env             # Exa + embedding keys optional
./scripts/start_engine.sh        # ws://127.0.0.1:8765
```

### 3. Agent server + extension (dev)

```bash
# One command — engine + BrowserOS agent HMR
chmod +x scripts/start_browseros.sh
./scripts/start_browseros.sh
```

Or manually:

```bash
cd BrowserOS/packages/browseros-agent
bun install
OPENHIVE_ENABLED=1 bun run dev:watch
```

Load the unpacked extension from `apps/agent/dist` into BrowserOS (dev mode), or use the built-in agent extension when running official BrowserOS with the server attached.

### 4. Use workflows

1. Browse normally — clicks/navigate/type are recorded via the content script → `/openhive/observe` → Python observer
2. Open the **side panel** → **Workflows** card → enter a name → **Save**
3. Click **Run** on a saved workflow — CDP executes actions (real clicks, not WKWebView JS)

## API (agent server)

All routes on `http://127.0.0.1:{serverPort}/openhive`:

| Route | Method | Purpose |
|-------|--------|---------|
| `/status` | GET | Engine connected, step count, workflows |
| `/workflows` | GET | Saved workflow list |
| `/compile` | POST | `{ "name": "my flow" }` |
| `/execute` | POST | `{ "workflowId": "..." }` |
| `/cancel` | POST | Stop run |
| `/observe` | POST | Passive observation event |
| `/exa` | POST | `{ "query": "..." }` |

## Feature parity checklist

| Feature | Status |
|---------|--------|
| Real browser automation (CDP) | ✅ BrowserOS native |
| Multi-model chat | ✅ BrowserOS LLM hub / side panel |
| Passive workflow recording | ✅ Content script + Python observer |
| Compile workflow | ✅ Side panel Save |
| Zero-token policy replay | ✅ Python executor + CDP bridge |
| Exa search | ✅ Python `exa_search` (wire to new tab UI next) |
| Token metrics / HUD grading | ✅ Python engine (dashboard TBD in extension) |
| Nook tabs/spaces/profiles | ❌ Use BrowserOS vertical tabs + profiles |

## Repo layout

```
yc/
├── BrowserOS/                 # Fork of browseros-ai/BrowserOS (cloned)
│   └── packages/browseros-agent/
│       ├── apps/server/       # + openhive bridge
│       └── apps/agent/        # + observation + workflows panel
├── python/                    # OpenHive engine (unchanged)
├── Nook/                      # Legacy shell — deprecated for this direction
└── scripts/start_browseros.sh
```

## Building BrowserOS Chromium (optional)

Full browser build requires ~100GB disk. See `BrowserOS/packages/browseros/`. For most development, use the **prebuilt BrowserOS app** + dev agent extension only.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENHIVE_ENABLED` | `1` | Start WebSocket bridge in agent server |
| `OPENHIVE_ENGINE_URL` | `ws://127.0.0.1:8765` | Python engine |
| `OPENHIVE_USE_PLAYWRIGHT` | `0` | Legacy separate Chromium window |

## License note

BrowserOS is **AGPL-3.0**. Nook is **GPL-3.0**. OpenHive Python engine follows this repo’s license. Distribution of modified BrowserOS builds must comply with AGPL source-offer requirements.
