#!/usr/bin/env bash
# Start OpenHive engine for Nook (Swift browser)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Starting OpenHive engine for Nook…"
"$ROOT/scripts/start_engine.sh"
