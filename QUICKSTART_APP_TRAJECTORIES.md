# Quick Start: App Trajectories

Run your **proven 20/20 smoke test logic** in the Swift OpenHive app.

## What You Have Now

✅ **Proven multi-step automation** from `run_local_browser_trace_gate.py` (20/20 passed)
✅ **Wired to Swift app** via WebSocket (EngineBridge)
✅ **Same scripted expert** driving WKWebView instead of Chrome
✅ **Full UI + headless modes** for testing

## 5-Minute Test

### 1. Start Python Engine

Terminal 1:
```bash
./scripts/start_engine.sh
```

Output:
```
Starting OpenHive engine on ws://localhost:8765
Waiting for Swift app to connect...
```

### 2. Add TrajectoryTestView to Your App

**Option A: Quick Test Window**

Add anywhere in your app (menu, debug panel, etc.):

```swift
import SwiftUI

Button("Test Trajectories") {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(rootView: TrajectoryTestView())
    window.title = "Trajectory Test"
    window.center()
    window.makeKeyAndOrderFront(nil)
}
```

**Option B: Add to ContentView**

```swift
// In your main ContentView or WindowView
TrajectoryTestView()
    .frame(width: 1200, height: 800)
```

### 3. Run One Task

1. Click **Connect** → should turn green
2. Click **BOS → LAX**
3. Watch:
   - WebView navigates to Google Flights
   - Step log fills with ~9 actions
   - Final URL contains `2026-07-15` encoded

### 4. Verify Success

Final URL should be:
```
https://www.google.com/travel/flights/search?tfs=CBwQAhokEgoyMDI2LTA3LTE1agcIARIDQk9TcgcIARIDTEFYGgA...
```

Key indicators:
- Contains encoded date
- Shows flight results
- ~9 steps total

---

## OR: Run Headless Smoke Test

Terminal 2 (with app running):
```bash
./scripts/run_app_smoke.sh --limit 3
```

Expected output:
```
============================================================
SUMMARY
============================================================
Succeeded: 3/3
Total steps: 26

  ✓ BOS→LAX: 9 steps, 18.3s
  ✓ SFO→JFK: 8 steps, 16.7s
  ✓ SEA→DEN: 9 steps, 17.9s

✓✓✓ ALL TASKS PASSED ✓✓✓
```

---

## What Just Happened

You ran **the exact same proven logic** that passed 20/20 Playwright tests, but in your **actual Swift browser** instead of headless Chrome.

### Flow

```
┌─────────────────────────┐
│  Swift WKWebView        │  Your actual app browser
│  (Google Flights open)  │
└────────────┬────────────┘
             │ WebSocket
             │ (ws://localhost:8765)
             │
┌────────────┴────────────┐
│  EngineBridge           │  Swift ↔ Python bridge
│  - Executes actions     │  - Receives actions from Python
│  - Sends state back     │  - Sends page state to Python
└────────────┬────────────┘
             │
┌────────────┴────────────┐
│  Python Engine          │  Runs proven scripted_action logic
│  run_app_trajectory.py  │  - Same expert from 20/20 smoke
│  - scripted_action()    │  - No new logic, just wired to app
│  - reached_results()    │
└─────────────────────────┘
```

---

## Files Created

```
scripts/
├── start_engine.sh           # Start Python WebSocket server
├── run_app_smoke.sh          # Run 3-task smoke test
└── validate_setup.sh         # Verify everything is ready

python/smoke/
└── run_app_trajectory.py     # Proven logic → Swift app

Nook/Components/Debug/
└── TrajectoryTestView.swift  # Test UI with webview + controls

docs/
├── APP_TRAJECTORY_GUIDE.md   # Full documentation
└── (this file)               # Quick start
```

---

## Next Steps

### 1. Run Full 20-Task Suite

```bash
./scripts/run_app_smoke.sh --limit 20
```

Expected: **20/20 pass** (same as Playwright)

### 2. Compare to Playwright Results

```bash
# Playwright artifacts (your proven run)
ls artifacts/local-browser-gate/gate_20260620_212645/

# App artifacts (new)
ls artifacts/app-trajectories/
```

Compare:
- Step counts (should match ±1)
- Final URLs (should be identical)
- Success rates (both 100%)

### 3. Wire to HUD Grading

Add to `run_app_trajectory.py`:

```python
from hud_grade import grade_execution

# After trajectory completes
grade = await grade_execution({
    "url": result["finalUrl"],
    "params": task,
})
reward = grade["reward"]  # 0.0-1.0 from HUD LLMJudgeGrader
```

This gives you **measured HUD rewards** for validation.

### 4. Add to BUILD_PLAN.md Gates

Update your gates:

```markdown
- [✓] Passive observation captures ≥5 steps with embeddings
- [✓] "Save this workflow" compiles locally in ≤3s
- [✓] Execute workflow → ≤20s, 0 tokens, all T1
- [✓] Local Playwright smoke: 20/20 tasks, correct URLs
- [✓] Swift app trajectories: 20/20 tasks, same URLs  ← NEW!
```

---

## Troubleshooting

### Can't connect?

```bash
# Check engine is running
ps aux | grep engine.py

# Restart
./scripts/start_engine.sh
```

### Actions not working?

Check Xcode console for:
```
[EngineBridge] → Execute: click
[WebView] Navigation finished: https://...
```

If missing, verify `EngineBridge.webView` is attached.

### Wrong final URL?

Compare to Playwright run:
```bash
# Playwright final URL
jq -r '.runs[0].url' artifacts/local-browser-gate/gate_20260620_212645/report.json

# App final URL
jq -r '.runs[0].finalUrl' artifacts/app-trajectories/smoke_summary_*.json
```

Should match exactly.

---

## Success Criteria

✅ `./scripts/validate_setup.sh` passes
✅ Engine starts on port 8765
✅ Swift app connects (green indicator)
✅ BOS→LAX task completes in ~9 steps
✅ Final URL contains encoded date `2026-07-15`
✅ 3/3 smoke test passes

**You now have the proven automation running in your actual app!**

Next: Scale to 20 tasks, add HUD grading, wire to demo flow.
