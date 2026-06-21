#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs artifacts/browser-use-benchmark
if [[ -f .env ]]; then set -a; source .env; set +a; fi
source .venv/bin/activate 2>/dev/null || true
pip install -q -r python/requirements.txt 2>/dev/null || pip install -q browser-use playwright openai
python -m playwright install chromium 2>/dev/null || true
export OPENHIVE_USE_BROWSER_USE=1
export OPENHIVE_AGENT_MODEL="${OPENHIVE_AGENT_MODEL:-gpt-4o}"
export OPENHIVE_AGENT_MAX_STEPS="${OPENHIVE_AGENT_MAX_STEPS:-40}"
export OPENHIVE_HEADLESS="${OPENHIVE_HEADLESS:-0}"
export BENCHMARK_LIMIT="${BENCHMARK_LIMIT:-3}"
echo "Running browser-use flight benchmark (limit=$BENCHMARK_LIMIT)..."
exec python python/smoke/run_browser_use_benchmark.py
