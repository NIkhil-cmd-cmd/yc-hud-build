# Holistic Trace Data Plan

## Summary

Create `docs/TRACE_DATA_PLAN.md` describing a framework-agnostic trace dataset for OpenHive. The dataset should support the current DOM/accessibility + embedding policy, while preserving enough visual, browser, timing, and outcome data to switch frameworks later.

Use a **Hackathon 100** collection plan: attempt about 100 traces, retain high-quality successful trajectories, and reserve 10-15 held-out eval tasks. Assume **no logged-in accounts**. Use DeepSeek as the first expert candidate if structured tool use is reliable; otherwise fall back to MiniMax thinking.

## Trace Artifacts To Capture

Each run should produce a single trace folder or archive with both structured records and raw artifacts.

- Step-level structured data:
  - task prompt, params, run id, timestamp, URL
  - action type, action args, selected element/ref, model rationale if available
  - reward, grader notes, success/failure label
  - token usage, latency, model/provider, tier used
- DOM/browser state:
  - accessibility tree snapshot
  - visible DOM snapshot or Playwright locator snapshot
  - current URL, title, viewport size, device scale factor
  - candidate interactive elements with text, role, bbox, selector/ref, enabled/visible state
- Visual state:
  - full-page screenshot per step
  - viewport screenshot per step
  - cropped screenshot around selected/candidate element
  - optional run video for debugging and demos
- Geometry and interaction:
  - element bounding boxes
  - click/type coordinates if used
  - scroll position
  - focused element before/after action
  - mouse/keyboard event metadata where available
- Network/runtime context:
  - HAR or lightweight request log
  - console errors/warnings
  - page load timings and wait conditions
  - redirects and navigation events
- Semantic/model artifacts:
  - state embedding
  - element embedding
  - normalized state text used for embedding
  - model output before parsing
  - parsed action JSON
- Environment metadata:
  - browser version
  - harness version/git SHA
  - HUD environment id/session id
  - provider/model versions
  - collection config id
  - random seed if applicable

## Collection Strategy

- Start with 5-10 manual gold traces to validate that all modalities are captured correctly.
- Run 50-70 LLM expert traces across diverse Google Flights tasks.
- Run 15-20 targeted traces for brittle states:
  - autocomplete
  - date picker
  - airport ambiguity
  - popups/interstitials
  - result filtering/sorting
  - airline handoff
- Reserve 10-15 held-out eval tasks that are never used for training.
- Keep no-login public flows only:
  - Google Flights search
  - results page
  - public airline handoff
  - no checkout requiring personal data

## Dataset Format

- Store each run as:
  - `trace.jsonl` for step records
  - `metadata.json` for run-level info
  - `screenshots/step_000_viewport.png`
  - `screenshots/step_000_fullpage.png`
  - `screenshots/step_000_element.png` when applicable
  - `accessibility/step_000.json`
  - `dom/step_000.html` or normalized DOM JSON
  - `network/run.har` or `network/events.jsonl`
  - `video/run.webm` when enabled
- Keep the structured schema stable even if the agent framework changes.
- Avoid relying on framework-specific IDs as the only source of truth; always pair refs/selectors with text, role, bbox, screenshot crop, and URL.

## Testing And Evaluation Set

- Build a held-out multimodal test set from successful and difficult traces.
- Include route/date diversity:
  - domestic easy routes
  - airport ambiguity routes
  - international routes
  - one-way and round-trip dates
  - month-boundary date picker cases
- Evaluate future frameworks against the same trace bundle using:
  - final task reward
  - step success
  - action match against gold trace
  - element match by bbox/role/text
  - visual state similarity where useful
  - time to completion
  - token usage
  - fallback tier count
- Keep partial/failure traces in a separate quarantine split for debugging and robustness work.

## Acceptance Criteria

- 100 trace attempts with complete metadata.
- At least 40 high-quality traces with reward `>= 0.8`.
- At least 5 manual gold traces with screenshots, accessibility trees, DOM snapshots, and action metadata verified by hand.
- Every retained training trace has enough data to replay or inspect without the original framework.
- Held-out eval set includes DOM/accessibility, screenshots, geometry, network/runtime logs, and reward labels.
- Demo task still completes in `<= 20s` with 0 LLM tokens on the ideal T1 path.

## Assumptions

- No login-based Google or airline flows for v1.
- DeepSeek is used only if a 3-run smoke test confirms reliable structured tool/action output.
- If screenshot/video storage becomes large, keep all screenshots but make video optional for non-gold traces.
- If HAR capture is too heavy, store a lightweight request/navigation log instead.
