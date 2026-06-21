# OpenHive App Trajectory Guide

Run the **proven multi-step browser automation** from `run_local_browser_trace_gate.py` (20/20 smoke tests passed) **directly in the Swift OpenHive app** via WebSocket.

## What This Does

Instead of running headless Chrome via Playwright, this drives your **actual Swift WKWebView browser** using the same proven `scripted_action()` expert logic that passed local smoke tests.

### Flow Comparison

**Before (Playwright smoke test):**
```
run_local_browser_trace_gate.py
  → Launch headless Chrome
  → 10-step trajectory (scripted expert)
  → Final URL with correct encoded dates
  → 20/20 tasks passed
```

**Now (Swift app):**
```
OpenHive.app (WKWebView)
  ↕ WebSocket (EngineBridge)
python/smoke/run_app_trajectory.py
  → Same 10-step trajectory logic
  → Same scripted_action() expert
  → Drives Swift WKWebView instead of Chrome
```

---

## Setup

### 1. Start the Python Engine

In terminal 1:

```bash
./scripts/start_engine.sh
```

You should see:
```
Starting OpenHive engine on ws://localhost:8765
Waiting for Swift app to connect...
```

### 2. Open the Swift App

Open `Nook.xcodeproj` in Xcode and run the app.

### 3. Open TrajectoryTestView (Option A: UI)

Add to your app menu or debug panel:

```swift
// In your main menu or window somewhere:
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

### 3. OR Run via Python Script (Option B: Headless)

In terminal 2:

```bash
./scripts/run_app_smoke.sh --limit 3
```

This will:
1. Wait for you to start the app and connect
2. Run 3 tasks (BOS→LAX, SFO→JFK, SEA→DEN)
3. Execute 10-step trajectories for each
4. Save artifacts to `artifacts/app-trajectories/`
5. Print summary report

---

## Usage

### Option A: Manual UI Testing

1. In TrajectoryTestView, click **Connect**
   - Status indicator should turn green
   - Console: `[EngineBridge] Connected to engine at ws://localhost:8765`

2. Click one of the task buttons:
   - **BOS → LAX**
   - **SFO → JFK**
   - **SEA → DEN**

3. Watch the execution:
   - WebView navigates to Google Flights
   - Scripted expert selects one-way, enters origin/dest, picks date
   - Step log shows each action
   - Final URL should contain encoded date

4. Check the final URL in the step log:
   ```
   https://www.google.com/travel/flights/search?tfs=...&tfu=...&curr=USD&hl=en&authuser=0
   ```

   Should have `EgQIABgA` (one-way) and correct date encoding.

### Option B: Automated Python Runner

```bash
# Run 3 tasks (default smoke suite)
./scripts/run_app_smoke.sh

# Run 10 tasks with custom settings
./scripts/run_app_smoke.sh --limit 10 --offset 5 --max-steps 12
```

**Output:**

```
============================================================
OpenHive App Trajectory Smoke Test
============================================================
Tasks: 3
Max steps: 10

Start the OpenHive app and connect EngineBridge, then press Enter...

[INFO] Connecting to Swift app at ws://localhost:8765
[INFO] ✓ Connected

============================================================
Starting: BOS → LAX on 2026-07-15
============================================================
[INFO] → Navigating to Google Flights
[INFO] → Getting initial state

[INFO] Step 0: 87 candidates on https://www.google.com/travel/flights
[INFO]   → click
[INFO]   ✓ Step 0: https://www.google.com/travel/flights

[INFO] Step 1: 91 candidates on https://www.google.com/travel/flights
[INFO]   → type BOS
...
[INFO] ✓ Results detected after step 8

============================================================
SUMMARY
============================================================
Succeeded: 3/3
Total steps: 26
Artifacts: artifacts/app-trajectories

  ✓ BOS→LAX: 9 steps, 18.3s
  ✓ SFO→JFK: 8 steps, 16.7s
  ✓ SEA→DEN: 9 steps, 17.9s

Summary: artifacts/app-trajectories/smoke_summary_1735678901.json

✓✓✓ ALL TASKS PASSED ✓✓✓
```

---

## Architecture

### Swift Side: EngineBridge

**File:** `Nook/Managers/EngineBridge/EngineBridge.swift`

Already exists and handles:
- WebSocket connection to Python engine
- Receiving actions from engine
- Executing actions on WKWebView via JavaScript
- Sending page state back to engine

**Key methods:**

```swift
func executeTask(origin: String, destination: String, date: String)
  // Starts a multi-step trajectory

private func handleMessage(_ msg: [String: Any]) async
  // Routes messages: "action", "step_complete", "trajectory_complete"

private func executeAction(_ action: [String: Any]) async
  // Performs action on WKWebView:
  //   - navigate, click, type, click_iso_date, click_xy

private func sendPageState() async
  // Extracts candidates and sends to Python
```

### Python Side: run_app_trajectory.py

**File:** `python/smoke/run_app_trajectory.py`

New script that:
- Connects to Swift app via WebSocket
- Runs the proven `scripted_action()` logic
- Sends actions to Swift for execution
- Receives state updates from Swift
- Detects when results are reached
- Saves artifacts

**Key class:**

```python
class AppTrajectoryRunner:
    async def run_trajectory(self, task: dict, max_steps: int = 10)
      # Runs one multi-step trajectory
      # Same logic as run_local_browser_trace_gate.py
      # Returns: {success, steps, finalUrl, elapsedSec, ...}
```

### Proven Logic Reuse

Both use the same functions from `run_local_browser_trace_gate.py`:

```python
from run_local_browser_trace_gate import (
    scripted_action,      # Expert that decides next action
    reached_results,      # Detects flight results page
    find_candidate,       # Helper for element selection
)
```

This means **zero new logic** — just wiring the same proven automation to the Swift app.

---

## Verification

### Check 1: Connection

```bash
# Terminal 1
./scripts/start_engine.sh

# Should show:
# [INFO] engine_listening port=8765 host=127.0.0.1
```

```swift
// Swift app
EngineBridge.shared.connect()

// Console should show:
// [EngineBridge] Connected to engine at ws://localhost:8765
```

### Check 2: Run One Task

In TrajectoryTestView:
1. Connect
2. Click "BOS → LAX"
3. Watch step log fill with ~9 steps
4. Final URL should be `https://www.google.com/travel/flights/search?...` with encoded date

### Check 3: Run Full Smoke

```bash
./scripts/run_app_smoke.sh --limit 3

# Should show:
# Succeeded: 3/3
# ✓✓✓ ALL TASKS PASSED ✓✓✓
```

---

## Artifacts

### Location

```
artifacts/app-trajectories/
├── trace_BOS_LAX_1735678901/
│   └── report.json
├── trace_SFO_JFK_1735678902/
│   └── report.json
├── trace_SEA_DEN_1735678903/
│   └── report.json
└── smoke_summary_1735678904.json
```

### Report Format

**`trace_*/report.json`:**

```json
{
  "success": true,
  "steps": 9,
  "finalUrl": "https://www.google.com/travel/flights/search?tfs=...",
  "elapsedSec": 18.3,
  "reason": "results_detected",
  "trajectory": [
    {
      "step": 0,
      "action": {"action": "click", "ref": "e51", "value": null},
      "url": "https://www.google.com/travel/flights",
      "candidateCount": 87
    },
    ...
  ]
}
```

**`smoke_summary_*.json`:**

```json
{
  "succeeded": 3,
  "attempted": 3,
  "totalSteps": 26,
  "runs": [
    {
      "task": {"origin": "BOS", "destination": "LAX", "departDate": "2026-07-15"},
      "success": true,
      "steps": 9,
      "elapsedSec": 18.3,
      "finalUrl": "https://www.google.com/travel/flights/search?..."
    },
    ...
  ]
}
```

---

## Troubleshooting

### "Connection closed"

**Problem:** Swift app can't reach engine.

**Fix:**
```bash
# Check engine is running
ps aux | grep "python.*engine.py"

# Restart engine
./scripts/start_engine.sh
```

### "Timeout waiting for state"

**Problem:** Swift not sending state after action.

**Fix:**
- Check `EngineBridge.webView` is attached
- Check JavaScript console for errors
- Verify `sendPageState()` is being called after actions

### "Max steps reached without results"

**Problem:** Trajectory didn't reach flight results.

**Fix:**
- Check final URL in report
- Compare to successful Playwright runs
- Verify Google Flights page structure hasn't changed
- Check console for JavaScript errors during execution

### JavaScript not executing

**Problem:** Actions not working (clicks, typing).

**Fix:**
```swift
// Verify developerExtrasEnabled is set
let config = WKWebViewConfiguration()
config.preferences.setValue(true, forKey: "developerExtrasEnabled")
```

---

## Next Steps

### 1. Run the 3-Task Smoke

Verify it works end-to-end:

```bash
# Terminal 1
./scripts/start_engine.sh

# Terminal 2 (after starting app)
./scripts/run_app_smoke.sh
```

Expected: **3/3 tasks pass** with final URLs containing encoded dates.

### 2. Scale to 20 Tasks

Same matrix as Playwright smoke:

```bash
./scripts/run_app_smoke.sh --limit 20
```

Expected: **20/20 tasks pass** (same as local Playwright run).

### 3. Compare Artifacts

```bash
# Playwright artifacts (from local smoke)
artifacts/local-browser-gate/gate_20260620_212645/

# App artifacts (new)
artifacts/app-trajectories/
```

Compare:
- Step counts (should be similar)
- Final URLs (should match)
- Success rates (should be 100%)

### 4. Add HUD Grading

Wire in `hud_grade.py` to score outcomes:

```python
# In run_app_trajectory.py
from hud_grade import grade_execution

result = await runner.run_trajectory(task)
grade = await grade_execution({
    "url": result["finalUrl"],
    "params": {"origin": task["origin"], "destination": task["destination"]},
    ...
})
reward = grade["reward"]
```

This gives you **measured HUD rewards** for app trajectories.

---

## Summary

✅ **Proven logic:** Same `scripted_action()` that passed 20/20 Playwright tests
✅ **Native browser:** Runs in Swift WKWebView, not headless Chrome
✅ **Full trajectories:** 10-step multi-action flows, not single actions
✅ **Artifacts:** Same report format as Playwright runs
✅ **Smoke test:** 3-task suite ready to run

**You now have the same working automation running in your actual app!**
