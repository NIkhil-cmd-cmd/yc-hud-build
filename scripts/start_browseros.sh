#!/usr/bin/env bash
# Start OpenHive engine + bridge server + BrowserOS with Hive UI baked in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.bun/bin:${PATH}"

BROWSER="/Applications/BrowserOS.app/Contents/MacOS/BrowserOS"
USER_DATA="${HOME}/Library/Application Support/BrowserOS"
CONFIG="${USER_DATA}/.browseros/server_config.json"
EXT_DIR="${ROOT}/BrowserOS/packages/browseros-agent/apps/agent/dist/chrome-mv3-dev"
OPENHIVE_PORT="${OPENHIVE_SERVER_PORT:-9210}"
LOG_DIR="${ROOT}/logs"
mkdir -p "$LOG_DIR"

read_ports() {
  python3 - <<PY
import json, os
p = os.path.expanduser("${CONFIG}")
if os.path.isfile(p):
    d = json.load(open(p))
    ports = d.get("ports", {})
    print(ports.get("cdp", 9100))
    print(ports.get("server", 9200))
    print(ports.get("extension", 9300))
else:
    print(9100)
    print(9200)
    print(9300)
PY
}

echo "==> Python engine (ws://127.0.0.1:8765)"
if lsof -ti:8765 >/dev/null 2>&1; then
  echo "    Already running"
else
  nohup "$ROOT/scripts/start_engine.sh" >>"$LOG_DIR/engine.log" 2>&1 &
  sleep 2
fi

echo "==> Building Hive UI into BrowserOS extension"
if ! command -v bun >/dev/null 2>&1; then
  echo "Bun required: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi
AGENT_DIR="${ROOT}/BrowserOS/packages/browseros-agent/apps/agent"
cd "${ROOT}/BrowserOS/packages/browseros-agent"
[[ -d node_modules ]] || bun install
cd "$AGENT_DIR"
bun run codegen >/dev/null 2>&1 || true
bun run build:dev

if [[ ! -d "$EXT_DIR" ]]; then
  echo "    Build failed — missing $EXT_DIR"
  exit 1
fi
echo "    Built → $EXT_DIR"

echo "==> Launching BrowserOS with Hive UI"
if [[ ! -x "$BROWSER" ]]; then
  echo "    BrowserOS not installed at $BROWSER"
  echo "    Download: https://www.browseros.com/"
  exit 1
fi

# Relaunch so our UI replaces the stock extension.
if pgrep -f "BrowserOS.app/Contents/MacOS/BrowserOS" >/dev/null 2>&1; then
  osascript -e 'quit app "BrowserOS"' >/dev/null 2>&1 || true
  sleep 2
fi

PORTS=($(read_ports))
CDP_PORT="${PORTS[0]:-9100}"
SERVER_PORT="${PORTS[1]:-9200}"
EXT_PORT="${PORTS[2]:-9300}"

nohup "$BROWSER" \
  --no-first-run \
  --no-default-browser-check \
  --disable-browseros-extensions \
  --load-extension="$EXT_DIR" \
  --remote-debugging-port="$CDP_PORT" \
  --browseros-mcp-port="$SERVER_PORT" \
  --browseros-server-port="$SERVER_PORT" \
  --browseros-extension-port="$EXT_PORT" \
  --user-data-dir="$USER_DATA" \
  "chrome://newtab" >>"$LOG_DIR/browseros.log" 2>&1 &

echo "    BrowserOS starting (CDP :$CDP_PORT)"

echo "    Waiting for BrowserOS config…"
for _ in $(seq 1 45); do
  [[ -f "$CONFIG" ]] && break
  sleep 1
done

echo "==> OpenHive bridge (:$OPENHIVE_PORT)"
if lsof -ti:"$OPENHIVE_PORT" >/dev/null 2>&1; then
  echo "    Already running"
else
  cd "${ROOT}/BrowserOS/packages/browseros-agent/apps/server"
  export OPENHIVE_ENABLED=1
  nohup bun src/index.ts --config "$CONFIG" --server-port "$OPENHIVE_PORT" \
    >>"$LOG_DIR/openhive-server.log" 2>&1 &
  sleep 2
fi

echo
echo "Ready."
echo "  Engine:   ws://127.0.0.1:8765"
echo "  Bridge:   http://127.0.0.1:${OPENHIVE_PORT}/openhive/status"
echo "  Hive UI:  open a new tab"
curl -sf "http://127.0.0.1:${OPENHIVE_PORT}/openhive/status" 2>/dev/null | head -c 240 || true
echo
