#!/usr/bin/env bash
# Start engine with browser-use baseline agent enabled (Playwright Chromium + vision LLM).
# Use this to run/compare the agentic baseline — separate from native WKWebView product path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export OPENHIVE_USE_BROWSER_USE=1
export OPENHIVE_AGENT_MODEL="${OPENHIVE_AGENT_MODEL:-gpt-4o}"
export OPENHIVE_HEADLESS="${OPENHIVE_HEADLESS:-0}"
exec "$ROOT/scripts/start_engine.sh"
