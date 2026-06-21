#!/usr/bin/env bash
#
# Start the OpenHive Python engine on localhost:8765
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi
if [ -d .venv ]; then
    source .venv/bin/activate
fi

pip install -q -r python/requirements.txt 2>/dev/null || pip install -q websockets openai networkx pydantic exa-py "hud-python>=0.6.6" playwright "browser-use>=0.7"
python -m playwright install chromium 2>/dev/null || playwright install chromium
export OPENHIVE_USE_PLAYWRIGHT="${OPENHIVE_USE_PLAYWRIGHT:-0}"
export OPENHIVE_AGENT_PLAYWRIGHT="${OPENHIVE_AGENT_PLAYWRIGHT:-0}"
export OPENHIVE_USE_BROWSER_USE="${OPENHIVE_USE_BROWSER_USE:-1}"
export OPENHIVE_HEADLESS="${OPENHIVE_HEADLESS:-0}"
export OPENHIVE_AGENT_MODEL="${OPENHIVE_AGENT_MODEL:-gpt-4o}"
export OPENHIVE_AGENT_MAX_STEPS="${OPENHIVE_AGENT_MAX_STEPS:-40}"
export OPENHIVE_USE_SYSTEM_CHROME="${OPENHIVE_USE_SYSTEM_CHROME:-1}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
PORT="${OPENHIVE_ENGINE_PORT:-8765}"
# Reclaim port if a stale engine is still running
if lsof -ti:"$PORT" >/dev/null 2>&1; then
  echo "Port $PORT in use — stopping stale engine..."
  lsof -ti:"$PORT" | xargs kill -9 2>/dev/null || true
  sleep 0.5
fi

echo "Starting OpenHive engine on ws://localhost:8765"
echo "Waiting for Swift app to connect..."
echo ""

exec python python/engine.py
