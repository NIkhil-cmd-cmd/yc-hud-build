#!/usr/bin/env bash
# Build the Hive-branded extension and print load instructions for BrowserOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.bun/bin:${PATH}"

AGENT_DIR="$ROOT/BrowserOS/packages/browseros-agent/apps/agent"
EXT_OUT="$AGENT_DIR/dist/chrome-mv3-dev"

echo "==> Installing dependencies (if needed)"
cd "$ROOT/BrowserOS/packages/browseros-agent"
[[ -d node_modules ]] || bun install

echo "==> Building Hive extension (development branding)"
cd "$AGENT_DIR"
bun run codegen
bun run build:dev

if [[ ! -d "$EXT_OUT" ]]; then
  echo "Build failed — expected output at $EXT_OUT"
  exit 1
fi

echo
echo "✓ Extension built: $EXT_OUT"
echo
echo "Load it in BrowserOS:"
echo "  1. Open chrome://extensions (or BrowserOS equivalent)"
echo "  2. Enable Developer mode"
echo "  3. Click 'Load unpacked' → select:"
echo "     $EXT_OUT"
echo "  4. Disable the stock BrowserOS Assistant extension if both are active"
echo
echo "Then start services:"
echo "  ./scripts/start_engine.sh          # Python engine :8765"
echo "  ./scripts/start_browseros.sh       # OpenHive bridge :9210"
echo
