#!/usr/bin/env bash
# Reset the hardcoded flight demo skill so you can re-run "learn → replay".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/OpenHive"
ID="demo_flight_bos_sfo"
rm -f "$SUPPORT/skills/${ID}.json" "$SUPPORT/mdps/${ID}.json" "$SUPPORT/workflows/${ID}.json"
echo "Removed flight demo skill ($ID). Restart engine or refresh skills in Nook."
cd "$ROOT/python"
source ../.venv/bin/activate
python3 -c "
import asyncio
from task_index import rebuild_index
asyncio.run(rebuild_index())
print('Rebuilt skill index.')
"
