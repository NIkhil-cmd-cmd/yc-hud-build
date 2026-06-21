#!/usr/bin/env bash
#
# Validate that app trajectory setup is complete
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Validating OpenHive App Trajectory Setup"
echo "=========================================="
echo ""

# Check Python files
echo "✓ Checking Python files..."
if [ ! -f python/smoke/run_app_trajectory.py ]; then
    echo "✗ Missing: python/smoke/run_app_trajectory.py"
    exit 1
fi

if [ ! -f python/smoke/run_local_browser_trace_gate.py ]; then
    echo "✗ Missing: python/smoke/run_local_browser_trace_gate.py (needed for scripted_action)"
    exit 1
fi

if [ ! -f python/engine.py ]; then
    echo "✗ Missing: python/engine.py"
    exit 1
fi

echo "  - run_app_trajectory.py ✓"
echo "  - run_local_browser_trace_gate.py ✓"
echo "  - engine.py ✓"
echo ""

# Check Swift files
echo "✓ Checking Swift files..."
if [ ! -f Nook/Managers/EngineBridge/EngineBridge.swift ]; then
    echo "✗ Missing: Nook/Managers/EngineBridge/EngineBridge.swift"
    exit 1
fi

if [ ! -f Nook/Components/Debug/TrajectoryTestView.swift ]; then
    echo "✗ Missing: Nook/Components/Debug/TrajectoryTestView.swift"
    exit 1
fi

echo "  - EngineBridge.swift ✓"
echo "  - TrajectoryTestView.swift ✓"
echo ""

# Check scripts
echo "✓ Checking scripts..."
if [ ! -x scripts/start_engine.sh ]; then
    echo "✗ Missing or not executable: scripts/start_engine.sh"
    exit 1
fi

if [ ! -x scripts/run_app_smoke.sh ]; then
    echo "✗ Missing or not executable: scripts/run_app_smoke.sh"
    exit 1
fi

echo "  - start_engine.sh ✓"
echo "  - run_app_smoke.sh ✓"
echo ""

# Check docs
echo "✓ Checking documentation..."
if [ ! -f docs/APP_TRAJECTORY_GUIDE.md ]; then
    echo "✗ Missing: docs/APP_TRAJECTORY_GUIDE.md"
    exit 1
fi

echo "  - APP_TRAJECTORY_GUIDE.md ✓"
echo ""

# Check Python environment
echo "✓ Checking Python environment..."
if [ ! -d .venv ]; then
    echo "⚠ No .venv found (not critical, but recommended)"
else
    echo "  - .venv ✓"
fi

# Check dependencies
if [ -f .venv/bin/python ]; then
    echo "  Checking Python packages..."
    .venv/bin/python -c "import websockets" 2>/dev/null || echo "  ⚠ websockets not installed (run: pip install websockets)"
else
    echo "  ⚠ Can't check packages without .venv"
fi

echo ""

# Create artifact directory
mkdir -p artifacts/app-trajectories
echo "✓ Created artifacts/app-trajectories/"
echo ""

echo "=========================================="
echo "✓✓✓ Setup validation complete!"
echo ""
echo "Next steps:"
echo "  1. Start engine:     ./scripts/start_engine.sh"
echo "  2. Open Xcode:       open Nook.xcodeproj"
echo "  3. Run app and add TrajectoryTestView to your UI"
echo "  4. OR run headless:  ./scripts/run_app_smoke.sh"
echo ""
echo "See docs/APP_TRAJECTORY_GUIDE.md for full instructions."
echo ""
