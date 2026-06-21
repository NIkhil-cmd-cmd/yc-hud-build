#!/usr/bin/env bash
# Install curated browser workflows into ~/Library/Application Support/OpenHive
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/python"
source ../.venv/bin/activate
python3 seed_browser_workflows.py "$@"
