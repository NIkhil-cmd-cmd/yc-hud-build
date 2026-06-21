#!/usr/bin/env bash
#
# Train flight booking MDP policy from collected traces
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

echo "Training Flight Booking MDP Policy"
echo "==================================="
echo ""

# Find latest gate run if not specified
if [ -z "${1:-}" ]; then
    LATEST=$(ls -t artifacts/local-browser-gate/gate_* 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then
        echo "No gate runs found."
        echo "First collect traces: ./scripts/run_local_smoke.sh"
        exit 1
    fi
    echo "Using latest run: $(basename $LATEST)"
    echo ""
    exec python python/smoke/train_flight_policy.py --run-dir "$LATEST" "${@:2}"
else
    exec python python/smoke/train_flight_policy.py "$@"
fi
