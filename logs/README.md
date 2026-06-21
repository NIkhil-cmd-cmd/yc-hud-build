# OpenHive debug logs

Agents read these files directly — no paste needed.

| File | Source |
|------|--------|
| `engine.log` | Python WebSocket engine |
| `openhive-swift.log` | Swift app (EngineBridge, observation, workflows) |

Also mirrored to `~/Library/Application Support/OpenHive/logs/`.

Tail: `tail -f logs/engine.log logs/openhive-swift.log`
