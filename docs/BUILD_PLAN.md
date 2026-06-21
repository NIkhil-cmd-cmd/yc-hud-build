# OpenHive Browser — Build Plan

## The product

A native macOS browser that learns from you. You browse normally — it observes silently, builds a workflow in the background. Next time you ask, it executes automatically. Personalized to your preferences. Repeat tasks cost zero LLM tokens.

**RL framing:** The browser IS the RL environment. You are the expert. Your actions are demonstrations. The MDP is the compressed policy. Automated execution is policy rollout.

**No upload model:** All training data stays local (`~/Library/Application Support/OpenHive/`). Nothing is sent to a cloud training pipeline. Workflows are compiled on-device from observed actions or generated locally via scripts.

---

## Open-source browser base

Build on a fork — do not scaffold a browser from scratch. UI layout follows [Dia](https://www.diabrowser.com/); automation follows agent-native patterns.

### Candidates

| Project | Stars | License | macOS | Why consider |
|---------|-------|---------|-------|--------------|
| **[Nook](https://github.com/nook-browser/Nook)** | ~1.9k | GPL-3.0 | 15.5+ | **Best UI fit** — sidebar-first, vertical tabs, manager architecture, Metal shaders. Closest to Dia layout out of the box. |
| **[Aslan Browser](https://github.com/onorbumbum/aslan-browser)** | ~15 | MIT | 14+ | **Best agent fit** — built for AI agents. A11y-tree-first, learn mode (passive demo capture), JSON-RPC + Python SDK, Unix socket IPC. |
| **[Web](https://github.com/nuance-dev/Web)** | ~655 | MIT | 14+ | AI browser middle ground — SwiftUI + WKWebView, tab hibernation, model routing already wired. |
| **[Ora](https://github.com/the-ora/browser)** | ~2.1k | GPL-3.0 | 14+ | Native WebKit, XcodeGen — less sidebar-first than Nook. |

### Recommendation: Nook + Aslan engine patterns

| Layer | Source | Rationale |
|-------|--------|-----------|
| **Browser shell + UI** | Fork [Nook](https://github.com/nook-browser/Nook) | Sidebar-first SwiftUI, `TabManager`, `BrowserManager`, Metal shaders — skin with Liquid Glass. Dia layout map: right sidebar, vertical tabs, minimal toolbar. |
| **Observation + execution IPC** | Patterns from [Aslan](https://github.com/onorbumbum/aslan-browser) | A11y tree refs (`@e0`), learn mode → our passive observer, JSON-RPC over Unix socket to Python engine. Use Aslan Python SDK ideas; do not depend on shipping Chromium. |
| **Policy engine** | This repo (`python/`) | MDP training, embeddings, HUD eval — unchanged. |

**License note:** Nook is GPL-3.0. If hackathon submission requires MIT, fork [Web](https://github.com/nuance-dev/Web) instead and port Nook's sidebar components, or fork Aslan (MIT) and build Dia-style chrome on top.

**Integration approach:**
1. Fork Nook → rename to OpenHive, rebrand, add Liquid Glass materials
2. Add `EngineBridge` manager — WebSocket/Unix socket to `python/engine.py`
3. Wire Nook's WKWebView tabs to Aslan-style a11y tree export on each user action
4. Hide Aslan-style explicit learn UI — passive capture always on; compile via chat or `Cmd+Shift+S`

---

## Tokens dashboard

Live token accounting surfaced in-app — all numbers from measured API `usage` fields, never estimates.

### Placement (placeholder until UI mockup)

| Surface | What it shows | When visible |
|---------|---------------|--------------|
| **Sidebar metrics strip** | Current run: tokens · elapsed · active tier | During workflow execution only |
| **Tokens panel** (`Cmd+Shift+T`) | Full dashboard — collapsible sheet or sidebar section | Always accessible, low profile |
| **Per-workflow row** | Lifetime tokens + avg time for that workflow | Workflows list |
| **Session summary** | Today / this week totals by tier (T1/T2/T3) | Tokens panel header |

### Tokens panel layout (draft — replace with your mockup)

```
┌─ Tokens ────────────────────────────────────────┐
│  This session          Today          All time  │
│  0                     847           12,400     │
├─────────────────────────────────────────────────┤
│  By tier                                        │
│  T1 policy      ████████████████████  0         │
│  T2 Fireworks   ██                    200       │
│  T3 MiniMax     ████████              8,240     │
├─────────────────────────────────────────────────┤
│  Recent runs                                    │
│  Book flight · Run 2    0 tok · 15s · T1       │
│  Book flight · Learn    18,240 tok · 3:04 · T3 │
│  Chipotle order · Run 2 0 tok · 12s · T1       │
├─────────────────────────────────────────────────┤
│  vs Browser Use baseline (published)            │
│  OpenHive Run 2: 0 tok    Browser Use: ~15k/run │
└─────────────────────────────────────────────────┘
```

### Data model

```swift
struct TokenMetrics: Codable {
    var sessionTotal: Int
    var todayTotal: Int
    var allTimeTotal: Int
    var byTier: [Int: Int]           // 1 → 0, 2 → 200, 3 → 8240
    var recentRuns: [RunMetric]
    var lastUpdated: Date
}

struct RunMetric: Codable {
    var workflowId: String
    var workflowName: String
    var runType: String              // "learn" | "execute" | "chat"
    var tokens: Int                  // from API usage, validated
    var elapsedMs: Int
    var tierLog: [Int]
    var timestamp: Date
}
```

Persisted to `~/Library/Application Support/OpenHive/metrics/tokens.json`. Engine appends on every LLM call (T2/T3/chat) and every T1 execution (tokens = 0). Swift `TokenDashboardManager` subscribes via WebSocket `metric` events.

---

## Demo (2.5 min on stage)

**0:00** — Open OpenHive. Clean new tab: search field + model selector (Exa default). Sidebar collapsed. No chrome clutter.

**0:15** — Say: "Watch me book a flight." Browse Google Flights manually. No record button — the sidebar shows nothing except a faint learning indicator (optional, off by default for demo).

**0:20** — Complete booking manually (~2 min). Engine silently captured 8 actions and 6 page states.

**2:20** — Type in sidebar chat: "Save this as book cheapest flight." Workflow compiles in under 3s. Sidebar shows: "Book cheapest flight · 8 steps · ready."

**2:25** — New tab. Type: "Book me a flight to LA next Tuesday." Enter.

**2:28** — Browser navigates automatically. Sidebar: tier indicators all T1, token counter reads 0 (live from executor metrics, not estimated). Skill graph highlights nodes sequentially.

**2:43** — Done. "Flight found. $187 · Delta · nonstop." Elapsed: 15s (wall-clock, logged).

**2:45** — Side-by-side: You: 2:04 → OpenHive: 0:15. 8× faster. 0 tokens (verified).

---

## UI direction

### Reference: Dia browser (one-for-one layout)

Copy the [Dia browser](https://www.diabrowser.com/) layout — not Arc, not Chrome:

| Element | Dia pattern | OpenHive adaptation |
|---------|-------------|---------------------|
| Sidebar position | Right side, collapsible (`Cmd+S`) | Same — right floating panel |
| Sidebar top | AI chat / input | Workflow chat + "save this workflow" natural language |
| Sidebar middle | Vertical tab list with favicons | Same |
| Sidebar bottom | Pinned tabs, tab groups | Saved workflows (compact list, no emoji icons) |
| Toolbar | Minimal — domain visible, full URL on hover | Same — translucent, no heavy chrome |
| New tab | Centered search, clean | Exa search + model picker + workflow cards |
| Aesthetic | Polished, playful but restrained | Liquid Glass — system-native, not custom dark theme |

### Design system: Apple Liquid Glass (macOS Tahoe 26+)

Native SwiftUI only. No Electron. No web-based UI shell.

```swift
// Design tokens — system-adaptive, no custom dark palette
struct OpenHiveTheme {
    // Materials (Liquid Glass)
    static let sidebarGlass   = Glass.regular        // .glassEffect(.regular)
    static let toolbarGlass   = Glass.regular
    static let cardGlass      = Glass.regular.interactive()

    // Semantic colors — adapt light/dark automatically
    static let accent         = Color.accentColor    // system accent, single tint
    static let textPrimary    = Color.primary
    static let textSecondary  = Color.secondary
    static let success        = Color.green          // tier T1 only
    static let warning        = Color.orange         // tier T2
    static let fallback       = Color.red            // tier T3

    // Typography
    static let displayFont    = Font.system(.title, design: .rounded)
    static let bodyFont       = Font.system(.body)
    static let monoFont       = Font.system(.caption, design: .monospaced)

    // Layout
    static let sidebarWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 12
    static let sidebarPadding: CGFloat = 16
}
```

**Rules:**
- Use `.glassEffect(.regular)` on sidebar, toolbar, workflow cards — never mix `.regular` and `.clear` in the same view hierarchy
- No custom hex backgrounds (`#0F0F13` etc.) — let system materials handle depth
- SF Symbols only for icons — **no emojis anywhere in the UI**
- Tint accent sparingly: primary actions and active tier indicator only
- Sidebar default: visible but quiet; collapses to zero width in Focus Mode

### Sidebar (320pt, right, Liquid Glass)

```
┌────────────────────────┐
│  [workflow chat input] │  ← natural language: "save this", "run chipotle order"
├────────────────────────┤
│  Tab · google.com/fl.. │  ← vertical tabs, favicon + truncated title
│  Tab · delta.com/...   │
│  Tab · (pinned)        │
├────────────────────────┤
│  Workflows             │
│  Book cheapest flight  │  ← text only, step count, success %
│  Chipotle order        │
├────────────────────────┤
│  0 tokens · 0:15 · T1  │  ← metrics strip, monospace, only during execution
└────────────────────────┘
```

No Record button. No Stop button. No glowing red state. Learning happens silently; the only visible affordance is typing "save this workflow" in chat or pressing `Cmd+Shift+S`.

### New tab

```
┌──────────────────────────────────────────────────┐
│                                                  │
│              OpenHive                            │
│                                                  │
│   [Exa ▼]  [ Search or ask anything          ]   │
│   Models: Exa · MiniMax · Fireworks               │
│                                                  │
│   Workflows                                      │
│   ┌─────────────────────┐ ┌───────────────────┐  │
│   │ Book cheapest flight│ │ Chipotle order    │  │
│   │ 8 steps · 92% · 15s │ │ 6 steps · 95% · 12│  │
│   │       [Run]         │ │      [Run]        │  │
│   └─────────────────────┘ └───────────────────┘  │
│                                                  │
└──────────────────────────────────────────────────┘
```

### Workflows panel

```
┌──────────────────────────────────────────────────┐
│  Workflows                                       │
├──────────────────────────────────────────────────┤
│  Book cheapest flight                            │
│  8 nodes · 92% success · saved 5 min ago         │
│  [Run]  [Graph]  [Delete]                        │
├──────────────────────────────────────────────────┤
│  Order Chipotle bowl                             │
│  6 nodes · 95% success · saved yesterday         │
│  [Run]  [Graph]  [Delete]                        │
└──────────────────────────────────────────────────┘
```

---

## Passive observation (no record button)

Training data is created continuously as the user browses — not via an explicit record/stop flow.

### How it works

1. **Always-on observer** — `ObservationService` attaches to WKWebView via CDP. Captures clicks, inputs, and navigations only (filters scroll/mouseover noise).
2. **Step buffer** — Each action produces `(state_embedding, action, element_embedding, next_state_embedding)` stored in memory and appended to a session log on disk.
3. **Workflow compilation triggers** (any one):
   - User types "save this" / "remember this workflow" in sidebar chat
   - Keyboard shortcut `Cmd+Shift+S` (hidden affordance, not a visible button)
   - Auto-prompt after idle 30s following ≥5 meaningful actions on same task domain
4. **On compile** — `train.py` runs locally: graph build + value iteration → `workflow.json` saved to Application Support. Sidebar updates workflow list. No upload step.

### What the user sees

| Phase | UI |
|-------|-----|
| Browsing | Nothing, or optional 1px accent line in sidebar (Settings → "Show learning indicator") |
| Compiling | Brief materialize animation on sidebar workflow slot (~2s) |
| Ready | Workflow appears in list with step count and timestamp |
| Executing | Metrics strip: tokens · elapsed · tier |

---

## Data generation (local alternatives)

No cloud upload. Three ways to build training data:

| Method | When to use | Implementation |
|--------|-------------|----------------|
| **Passive observation** | Primary — demo and daily use | `recorder.py` via CDP during normal browsing |
| **HUD eval harvest** | Benchmark runs, reproducible trajectories | `python/datagen/hud_import.py` — run HUD `@env.template` tasks, export harvest JSON locally |
| **Modal parallel collect** | Bulk diversity (15 city pairs) without manual repetition | `python/datagen/modal_collect.py` — spawns harness subprocess, writes to local volume, syncs down |
| **Synthetic configs** | Fill gaps when live sites block automation | `python/datagen/synthetic.py` — generates `FlightParams` permutations; `scraper.py` replays against cached page snapshots |

All outputs land in `~/Library/Application Support/OpenHive/harvest/` and compile to `~/Library/Application Support/OpenHive/workflows/`. Gitignored. Never committed.

---

## Tech stack

| Layer | Technology | Role |
|-------|------------|------|
| **Browser base** | [Nook](https://github.com/nook-browser/Nook) (fork) | Sidebar-first SwiftUI shell, TabManager, BrowserManager |
| **UI shell** | Swift + SwiftUI + Liquid Glass | Dia-layout chrome, glass materials, no emojis |
| **Web content** | WKWebView (WebKit) | Native rendering; a11y tree export (Aslan pattern) |
| **Agent IPC** | Unix socket / WebSocket JSON-RPC | Swift `EngineBridge` ↔ Python `engine.py` (Aslan-inspired) |
| **Observation** | Swift LearnRecorder pattern + Python observer | Passive capture; no record button |
| **Token tracking** | `TokenDashboardManager` + `metrics/tokens.json` | Measured usage per tier, session, workflow |
| **Embeddings** | OpenAI `text-embedding-3-small` | 1536-d state and element vectors |
| **Policy training** | Python + NetworkX | Graph clustering (θ=0.88) + value iteration (γ=0.95) |
| **Execution** | Python + Browser Use | `PolicyAgent` — Tier 1 policy lookup, Tier 2/3 fallback |
| **Tier 2 fallback** | Fireworks Llama 3.1 8B | Fast model for unknown states (~200 tokens, measured) |
| **Tier 3 fallback** | MiniMax (no thinking_budget) | Emergency recovery only |
| **Search / schema** | Exa | New tab default search; `exa.answer()` for unknown page schemas |
| **Grading** | HUD + LLMJudgeGrader | Task structure, reward signal, SubagentStep traces |
| **Parallel eval** | Modal | 15× workflow consistency benchmark (local volume sync) |
| **Dev environment** | Daytona | `devcontainer.json` for reproducible Python engine setup |

**Explicitly not in stack:** Electron, Next.js dashboard, cloud training upload, emoji UI, explicit record/stop buttons.

---

## Architecture

```
┌────────────── Swift macOS App (SwiftUI + WKWebView) ──────────────┐
│                                                                    │
│  ┌─────────────────────────────┐  ┌──────────────────────────┐   │
│  │  WKWebView (browser)        │  │  SidebarView (Liquid     │   │
│  │  google.com/travel/flights│  │  Glass, right, 320pt)    │   │
│  │                             │  │  · chat input            │   │
│  │                             │  │  · vertical tabs         │   │
│  │                             │  │  · workflow list         │   │
│  │                             │  │  · metrics strip         │   │
│  └─────────────────────────────┘  └──────────────────────────┘   │
│                                                                    │
└──────────────────────── WebSocket ────────────────────────────────┘
                                    │
┌────────── Python Engine (localhost:8765) ──────────────────────────┐
│                                                                    │
│  observer.py    — passive CDP capture → step buffer → harvest      │
│  train.py       — graph + MDP → workflow.json (local disk)         │
│  executor.py    — PolicyAgent (Browser Use), tier logging           │
│  hud_env.py     — HUD environment + LLMJudgeGrader                 │
│  exa_client.py  — search + page schema                             │
│  datagen/       — hud_import, modal_collect, synthetic, scraper    │
└────────────────────────────────────────────────────────────────────┘
```

---

## File structure

```
yc-hud-build/
├── OpenHive/                          # Forked from Nook (Xcode project)
│   ├── Managers/
│   │   ├── EngineBridge/              # NEW — socket to python/engine.py
│   │   ├── TokenDashboardManager/     # NEW — tokens.json, WebSocket metrics
│   │   ├── WorkflowManager/           # NEW — compile, list, execute workflows
│   │   ├── BrowserManager/            # from Nook
│   │   └── TabManager/                # from Nook
│   ├── Components/
│   │   ├── Sidebar/                   # from Nook — rebrand, move right, Liquid Glass
│   │   ├── TokensPanel/               # NEW — full token dashboard (Cmd+Shift+T)
│   │   ├── MetricsStrip/              # NEW — live run strip during execution
│   │   └── Workflows/                 # NEW — workflow list + graph canvas
│   ├── Design/
│   │   ├── OpenHiveTheme.swift        # Liquid Glass tokens
│   │   └── GlassModifiers.swift
│   └── Utils/
│       └── WebKit/                    # from Nook + a11y tree export
├── python/
│   ├── engine.py                      # WebSocket server
│   ├── observer.py                    # Passive CDP capture (replaces recorder.py)
│   ├── embeddings.py                  # embedState(), embedElement()
│   ├── train.py                       # Graph builder + value iteration
│   ├── executor.py                    # PolicyAgent (Browser Use)
│   ├── hud_env.py                     # HUD @env.template + LLMJudgeGrader
│   ├── exa_client.py                  # exa.answer(), getPageSchema()
│   ├── modal_eval.py                  # Parallel benchmark
│   └── datagen/
│       ├── hud_import.py              # Import HUD trace → harvest JSON
│       ├── modal_collect.py           # Parallel collection → local volume
│       ├── synthetic.py               # FlightParams permutations
│       └── scraper.py                 # Cached page replay
├── docs/
│   ├── BUILD_PLAN.md                  # This file
│   ├── DEMO_SCRIPT.md
│   └── SUBMISSION.md
├── configs/
│   └── collection_configs.json        # 15 city-pair configs for datagen
├── pyproject.toml
├── .env.example
└── .devcontainer/
    └── devcontainer.json              # Daytona
```

Local data paths (never in repo):
```
~/Library/Application Support/OpenHive/
├── harvest/          # raw step logs (*.json)
├── workflows/        # compiled workflow_*.json
└── metrics/          # executor run logs for claim validation
```

---

## Claim validation

Every number shown in the UI or stated on stage must be **measured**, not estimated.

| Claim | Source | Validation |
|-------|--------|------------|
| 0 tokens on Run 2 | `executor.py` → `agent.tokens` from API `usage` fields | Assert `tokens == 0` when tier log is all T1 |
| ~15s execution time | Wall-clock `time.time()` in `run_workflow()` | Log to `metrics/{run_id}.json`; UI reads this file |
| 8× faster vs manual | Compare observation session duration vs execution duration | Both timestamps from local logs |
| 92% workflow success | HUD LLMJudgeGrader reward on N eval tasks | `modal_eval.py` → reward distribution |
| Tier breakdown | `agent.tier_log[]` per step | Sidebar renders from live WebSocket metrics |
| "~15k tokens Run 1" | **Estimate until measured** — label as est. in slides until first real collection run completes | Replace with actual `totalTokens` from harvest file |

**Pre-demo validation script** (`python/validate_claims.py`):
```python
# Runs before every demo rehearsal
# 1. Execute demo workflow (BOS→LAX)
# 2. Assert elapsed_ms <= 20000
# 3. Assert tokens == 0 (all T1)
# 4. Assert reward >= 0.75 via HUD eval
# 5. Write validated numbers to metrics/demo_latest.json
# UI dashboard reads demo_latest.json — never hardcoded
```

**Honesty note for stage:** Token counts for first-time learning runs are measured live. Published Browser Use SOTA numbers (68s, ~15k tokens) are third-party benchmarks — our comparison uses HUD-measured Run 2 vs those published baselines.

---

## Component sketches

### Swift: BrowserView + EngineClient

```swift
// BrowserView.swift — WKWebView with CDP URL forwarded to engine
struct BrowserView: NSViewRepresentable {
    @EnvironmentObject var engine: EngineClient

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        // Passive observation starts automatically on navigation
        engine.attachObservation(to: webView)
        return webView
    }
}

// EngineClient.swift
class EngineClient: ObservableObject {
    @Published var workflows: [Workflow] = []
    @Published var metrics: RunMetrics?    // tokens, elapsed, tier — execution only
    private var ws: URLSessionWebSocketTask?

    func saveWorkflow(name: String) {
        send(["type": "compile_workflow", "name": name])
    }

    func execute(workflowId: String, params: [String: String]) {
        send(["type": "execute", "workflowId": workflowId, "params": params])
    }
}
```

### Python: observer.py (passive, no start/stop)

```python
class Observer:
    """Always-on CDP observer. No record button — captures meaningful actions silently."""

    MEANINGFUL = {"click", "type", "navigate", "submit"}

    def __init__(self, cdp_url: str, on_step):
        self.cdp_url = cdp_url
        self.on_step = on_step
        self.buffer: list[dict] = []
        self.active = True  # on by default; disable in Settings

    async def _handle_event(self, event: dict):
        if not self.active or event.get("type") not in self.MEANINGFUL:
            return
        # ... embed state, append to buffer, persist to harvest/session_{id}.jsonl
        await self.on_step(step)

    def compile_workflow(self, name: str) -> dict:
        """Called when user says 'save this' or Cmd+Shift+S."""
        G = build_graph([{"harvest": self.buffer, "success": True}])
        policy = value_iteration(G)
        return save_workflow_locally(name, policy, self.buffer)
```

### Python: engine.py message types

```python
# WebSocket message types (no start_recording / stop_recording)
"compile_workflow"   # { name, session_id? } → trains from buffer, saves locally
"execute"            # { workflowId, params, cdpUrl }
"list_workflows"     # → workflows on disk
"import_harvest"     # { path } → compile external harvest file
"generate_synthetic" # { configs_path } → datagen/synthetic.py
"metric"             # engine → Swift: { tokens, tier, elapsed_ms, ... }
```

---

## Sponsor stack

| Sponsor | Role | Where it shows |
|---------|------|----------------|
| **HUD** | RL environment + task grading | `@env.template` task structure; LLMJudgeGrader scores execution; SubagentStep traces full run |
| **Exa** | Default new-tab search | Search bar; `exa.answer()` for unknown page schemas in Tier 2 |
| **MiniMax** | Tier 3 emergency fallback | Only when policy + Fireworks fail; also new-tab model option |
| **Fireworks** | Tier 2 fast fallback | Llama 3.1 8B for unknown states; new-tab model option |
| **Modal** | Parallel eval + datagen | 15× consistency benchmark; optional bulk harvest without manual browsing |
| **Daytona** | Dev environment | `devcontainer.json` — same Python engine on every machine |

---

## 48h build order

| Hours | Who | Task |
|-------|-----|------|
| 0–1 | Both | Fork Nook into repo, rebrand OpenHive, `pyproject.toml`, Modal secrets, `.env.example`, Daytona devcontainer |
| 1–4 | A | Nook sidebar → Dia layout (right side), Liquid Glass, `EngineBridge` + `TokenDashboardManager` skeleton |
| 1–3 | B | `engine.py` + `observer.py` passive capture + `embeddings.py` |
| 3–5 | B | `train.py` — graph + value iteration; test on mock harvest |
| 4–7 | A | `NewTabView`, `WorkflowsView`, `MetricsStripView` — no emojis, system materials only |
| 5–7 | Both | **Gate:** browse manually → `compile_workflow` via chat → harvest JSON with ≥5 embedded steps |
| 7–12 | B | `executor.py` PolicyAgent — Tier 1/2/3, measured token logging |
| 7–12 | A | `datagen/` — `hud_import.py`, `synthetic.py`, `modal_collect.py` |
| 12–14 | B | `hud_env.py` + `exa_client.py` |
| 12–14 | A | `validate_claims.py` — assert demo numbers before UI displays them |
| 14–18 | Both | **Gate:** passive observe → compile → execute → ≤20s, 0 tokens, all T1 |
| 18–22 | A | UI polish — Liquid Glass animations, Focus Mode (`Cmd+S`), graph canvas |
| 18–20 | B | `modal_eval.py` — 10 tasks, policy vs baseline |
| 20–24 | B | Run Modal datagen if manual harvest insufficient; sync to local workflows |
| 24–28 | Both | Record 2 more workflows (Chipotle, Amazon) via passive observation |
| 28–34 | Both | Demo rehearsal ×3; run `validate_claims.py` before each |
| 34–40 | Both | Buffer — CDP timing, cosine thresholds, autocomplete, WebSocket drops |
| 40–48 | Both | Submission form, README, slides (4), backup demo video |

---

## Key risks

| Risk | Fix |
|------|-----|
| WKWebView CDP URL access on macOS | Enable `developerExtrasEnabled`; use `WKWebView` inspector protocol; fallback to Playwright subprocess |
| Passive capture too noisy | Filter to click/type/navigate/submit only; debounce input events 300ms |
| User expects a Record button | Demo script explains "it just watches"; optional learning indicator in Settings |
| Liquid Glass requires macOS 26 / Xcode 26 | Target macOS 14+ with `.ultraThinMaterial` fallback; upgrade to `.glassEffect` when SDK available |
| browser-use `_get_next_action` API unstable | Pin version; override `step()` if needed |
| Claims shown before validation | UI reads `metrics/demo_latest.json` only; never hardcode numbers |
| Modal datagen vs "no upload" | Modal writes to volume; sync down to local disk — data never leaves your control |

---

## Success criteria

- [ ] Passive observation captures ≥5 steps with embeddings during normal browsing (no record button)
- [ ] "Save this workflow" compiles and saves locally in ≤3s
- [ ] Execute workflow → ≤20s, 0 tokens, tier log all T1 (validated by `validate_claims.py`)
- [ ] Fork builds and runs (Nook base rebranded as OpenHive)
- [ ] Tokens dashboard shows measured session/tier/run breakdown
- [ ] Swift UI: Dia-layout sidebar, Liquid Glass materials, zero emojis
- [ ] New tab: Exa search + model selector working
- [ ] Datagen: at least one alternative path (HUD import or synthetic) produces compilable harvest
- [ ] HUD eval: automated execution scores reward ≥0.75 on 8/10 tasks
- [ ] All demo numbers sourced from measured metrics, not estimates
- [ ] Demo rehearsed 3× under 2.5 minutes
- [ ] Public repo, submission form, 4-slide deck
