#!/usr/bin/env bash
# Run a cheap local HUD eval against HUD/env.py (no platform deploy).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/HUD"
source "$ROOT/.venv/bin/activate" 2>/dev/null || true
set -a
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
set +a

MODEL="${1:-claude-haiku-4-5}"
shift || true
echo "Local eval: HUD/env.py → $MODEL"
# --runtime hud provisions browser CDP for book_flight; omit for smoke_ping-only runs.
hud eval env.py "$MODEL" --max-steps 15 --runtime hud "$@"
