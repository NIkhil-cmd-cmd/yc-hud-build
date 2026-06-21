#!/usr/bin/env bash
# Start Nook with OpenHive in-tab agent engine (keys from .env)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${OPENHIVE_ENGINE_PORT:-8765}"

# Start engine in background if not already listening
if ! lsof -ti:"$PORT" >/dev/null 2>&1; then
  echo "Starting OpenHive agent engine (in-tab WKWebView)…"
  nohup "$ROOT/scripts/start_engine.sh" >>"$ROOT/logs/engine.log" 2>&1 &
  for _ in $(seq 1 30); do
    if lsof -ti:"$PORT" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
fi

echo "Engine → ws://127.0.0.1:${PORT}"
echo "Open Nook in Xcode or: open $ROOT/Nook.xcodeproj"
