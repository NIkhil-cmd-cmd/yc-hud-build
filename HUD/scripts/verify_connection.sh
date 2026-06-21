#!/usr/bin/env bash
# Smoke-test HUD API + local env template wiring.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/HUD"
source "$ROOT/.venv/bin/activate" 2>/dev/null || true
set -a
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
set +a
python connect.py "$@"
