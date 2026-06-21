# App Screenshots

Placeholder SVG mockups based on current OpenHive UI (`AgentHomeView`, `WorkflowGraphView`, `AgentNotchView`).

## Replace with live captures

1. Run Nook/OpenHive from Xcode
2. Capture at 2x retina:
   - New tab (agent home): `agent-home@2x.png`
   - Workflow graph view: `workflow-graph@2x.png`
   - Agent notch HUD during run: `agent-notch@2x.png`
3. Drop PNGs in this folder and update paths in `index.html`

## Capture script (macOS)

```bash
# After focusing the Nook window:
screencapture -l$(osascript -e 'tell app "Nook" to id of window 1') -x website/tera/assets/screenshots/agent-home@2x.png
```
