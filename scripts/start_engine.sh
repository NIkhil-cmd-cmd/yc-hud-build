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
pip install -q -r python/requirements.txt 2>/dev/null || pip install -q websockets openai networkx pydantic exa-py "hud-python>=0.6.6" playwright "browser-use>=0.7"
python -m playwright install chromium 2>/dev/null || playwright install chromium
export OPENHIVE_USE_PLAYWRIGHT="${OPENHIVE_USE_PLAYWRIGHT:-0}"
export OPENHIVE_AGENT_PLAYWRIGHT="${OPENHIVE_AGENT_PLAYWRIGHT:-0}"
export OPENHIVE_USE_BROWSER_USE="${OPENHIVE_USE_BROWSER_USE:-0}"
export OPENHIVE_HEADLESS="${OPENHIVE_HEADLESS:-0}"
export OPENHIVE_AGENT_MODEL="${OPENHIVE_AGENT_MODEL:-gpt-4o}"
export OPENHIVE_AGENT_MAX_STEPS="${OPENHIVE_AGENT_MAX_STEPS:-40}"
export OPENHIVE_USE_SYSTEM_CHROME="${OPENHIVE_USE_SYSTEM_CHROME:-1}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY missing — add it to .env (in-tab agent requires an LLM key)."
  exit 1
fi
PORT="${OPENHIVE_ENGINE_PORT:-8765}"
# Reclaim port if a stale engine is still running
if lsof -ti:"$PORT" >/dev/null 2>&1; then
  echo "Port $PORT in use — stopping stale engine..."
  lsof -ti:"$PORT" | xargs kill -9 2>/dev/null || true
  sleep 0.5
fi
cd python
if [[ "${OPENHIVE_USE_BROWSER_USE:-0}" == "1" ]]; then
  echo "Mode: external browser-use Chromium (benchmarks) — set OPENHIVE_USE_BROWSER_USE=0 for in-tab agent"
else
  echo "Mode: in-tab agent (Nook WKWebView + ${OPENHIVE_AGENT_MODEL:-gpt-4o}) — snapshot/@ref like agent-browser"
fi
echo "OpenHive engine → ws://127.0.0.1:${PORT}"
echo "Logs → $ROOT/logs/engine.log"
exec python engine.py
