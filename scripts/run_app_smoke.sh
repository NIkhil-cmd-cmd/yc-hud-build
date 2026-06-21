#!/usr/bin/env bash
#
# Run the 3-task smoke test in the Swift app
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Activate venv
if [ -d .venv ]; then
    source .venv/bin/activate
fi

echo "Running app trajectory smoke test..."
echo ""
echo "Make sure:"
echo "  1. OpenHive app is running"
echo "  2. EngineBridge is connected (ws://localhost:8765)"
echo "  3. Python engine is running (./scripts/start_engine.sh)"
echo ""

exec python python/smoke/run_app_trajectory.py "$@"
