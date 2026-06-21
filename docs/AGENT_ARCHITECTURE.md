# OpenHive Agent Architecture

## Decision (final)

**Product agent: native in-tab WKWebView** — snapshot → LLM → `@ref` action loop, executed in the user's current Nook tab.

| Library | Role in Nook |
|---------|----------------|
| **Native WKWebView agent** | **Default** — Dia new tab, plan mode, skills fallback |
| **browser-use (Playwright)** | Opt-in only (`OPENHIVE_USE_BROWSER_USE=1`) — benchmarks, `./scripts/start_engine_baseline.sh` |
| **agent-browser (Vercel)** | **Not embedded** — same CDP/Chrome model as browser-use; patterns ported (snapshot + refs) |
| **PolicyExecutor / skills** | Zero-token replay when KNN match exceeds threshold |

Neither browser-use nor agent-browser can drive WKWebView (no CDP on macOS WebKit). External Chrome violates the “one browser” requirement.

## Original goals checklist

| Goal | Status | Implementation |
|------|--------|----------------|
| Dia-style agent-first new tab | ✅ | `AgentHomeView`, `TabManager.createNewTab`, `WebsiteView` |
| Type task → agent runs (not URL) | ✅ | `AgentHomeView.submit()` → `matchTask` or `runAgent` |
| URL → normal navigation | ✅ | `looksLikeURL()` branch |
| Everything in one browser (no external Chrome) | ✅ | Default `OPENHIVE_USE_BROWSER_USE=0`, `AgentTaskSession` |
| Engine bridge + reconnect | ✅ | `EngineBridge`, `sendCriticalAndWait` |
| Notch HUD (steps, model, tokens) | ✅ | `AgentNotch/*`; tokens via `run_metric` |
| Skill match → confirm → MDP replay | ✅ | `matchTask` → `SkillConfirmSheet` → `confirm_run_skill` |
| Agent fallback when no skill match | ✅ | `shouldRunAgentAfterMiss` → `runAgent` |
| Plan mode (decompose + run subtasks) | ✅ | `start_plan` → `run_subtask` orchestration in `EngineBridge` |
| Record demo toggle | ✅ | Auto-compile workflow on run complete when enabled |
| Passive observation always on | ✅ | `OpenHiveObservation` injected on every tab load |
| Zero-config from `.env` | ✅ | `./scripts/start_engine.sh` |
| HUD benchmark (native vs external) | ✅ | Opt-in via `start_hud_benchmark` |

## Control loop (in-tab)

```
User types task in AgentHomeView
  → matchTask (KNN) → skill confirm OR agent
  → EngineBridge.startAgentTask → WS start_agent
  → engine._schedule_agent_task → AgentTaskSession.run
  → LLM (agent_llm.choose_next_action) reads candidates + pageText
  → execute_action → Swift WebViewAutomation.perform
  → execute_state (candidates from unified snapshot)
  → repeat until done / max_steps
```

## Startup

```bash
./scripts/start_engine.sh   # in-tab agent, port 8765
./scripts/start_nook.sh     # engine + open Xcode hint
```

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `OPENHIVE_USE_BROWSER_USE` | `0` | `1` = external Chromium (benchmarks only) |
| `OPENAI_API_KEY` | required | LLM for in-tab agent |
| `OPENHIVE_AGENT_MODEL` | `gpt-4o` | Model for agent steps |
| `OPENHIVE_AGENT_MAX_STEPS` | `40` | Max steps per task |

## Key files

| Area | Path |
|------|------|
| New tab UI | `Nook/Components/OpenHive/AgentHomeView.swift` |
| Bridge | `Nook/Managers/EngineBridge/EngineBridge.swift` |
| DOM automation | `Nook/Utils/WebKit/WebViewAutomation.swift` |
| Unified snapshot | `Nook/Utils/OpenHive/OpenHiveObservation.swift` |
| Agent loop | `python/agent_loop.py`, `python/agent_llm.py` |
| Engine routing | `python/engine.py` → `_schedule_agent_task` |
| Skills index | `python/task_index.py` |
| Plan orchestrator | `python/task_orchestrator.py` |

## Future improvements (not blocking)

- Trusted clicks via accessibility APIs for stubborn SPAs
- Wire `TaskRunView` MDP graph into compositor during skill replay
- Live HUD benchmark native arm (today reads cached `demo_latest.json`)
- Voice input on mic button
