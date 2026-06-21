#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs
mkdir -p "$HOME/Library/Application Support/OpenHive/logs"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r python/requirements.txt 2>/dev/null || pip install -q websockets openai networkx pydantic exa-py "hud-python>=0.6.6" playwright
python -m playwright install chromium 2>/dev/null || playwright install chromium
if [[ -f .env ]]; then set -a; source .env; set +a; fi
PORT="${OPENHIVE_ENGINE_PORT:-8765}"
# Reclaim port if a stale engine is still running
if lsof -ti:"$PORT" >/dev/null 2>&1; then
  echo "Port $PORT in use — stopping stale engine..."
  lsof -ti:"$PORT" | xargs kill -9 2>/dev/null || true
  sleep 0.5
fi
cd python
echo "OpenHive engine → ws://127.0.0.1:${PORT}"
echo "Logs → $ROOT/logs/engine.log"
exec python engine.py
