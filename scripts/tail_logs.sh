#!/usr/bin/env bash
# Tail OpenHive debug logs (agent-readable in yc/logs/)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tail -n "${1:-50}" -f "$ROOT/logs/engine.log" "$ROOT/logs/openhive-swift.log" 2>/dev/null || \
  tail -n "${1:-50}" -f "$HOME/Library/Application Support/OpenHive/logs/"*.log
