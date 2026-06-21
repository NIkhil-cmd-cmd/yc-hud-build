//
//  AgentHomeView.swift
//  OpenHive — Dia-style agent-first new tab (type task → agent runs in this tab)
//

import SwiftUI
import WebKit
import AppKit

struct AgentHomeView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(MCPManager.self) private var mcpManager
    @Environment(AIConfigService.self) private var configService
    @Bindable private var engine = EngineBridge.shared
    @Bindable private var runState = TaskRunState.shared
    @Bindable private var tokens = TokenDashboardManager.shared

    @State private var query = ""
    @State private var showAdvanced = false
    @State private var landingAppeared = false
    @FocusState private var isFocused: Bool

    private let placeholder = "Describe a task, or paste a URL"

    var body: some View {
        ZStack {
            agentBackground

            if isOrchestratingThisTab, runState.phase == .matching {
                matchingOverlay
            } else {
                diaHome
            }
        }
        .sheet(isPresented: $runState.showSkillConfirm) {
            if let match = runState.pendingMatch {
                SkillConfirmSheet(
                    match: match,
                    onRunSkill: { confirmRunSkill() },
                    onUseAgent: { runAgent() },
                    onCancel: {
                        runState.showSkillConfirm = false
                        runState.phase = .idle
                    }
                )
            }
        }
        .onAppear {
            engine.refreshSkills()
            tokens.refresh()
            AgentNotchPanelController.shared.show()
            if let tab = browserManager.currentTab(for: windowState) {
                _ = browserManager.ensureWebView(for: tab.id, in: windowState.id)
            }
            EngineBridge.shared.setAgentModelPreference(
                provider: runState.selectedAgentModel.provider,
                model: runState.selectedAgentModel.model
            )
            landingAppeared = false
            withAnimation(.spring(response: 0.72, dampingFraction: 0.84)) {
                landingAppeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isFocused = true }
        }
        .onChange(of: runState.shouldRunAgentAfterMiss) { _, should in
            if should {
                runState.shouldRunAgentAfterMiss = false
                guard !FlightDemoRouter.isFlightPrompt(runState.prompt) else { return }
                runAgent()
            }
        }
        .onChange(of: engine.flightDemoLearnPending) { _, pending in
            if pending {
                engine.flightDemoLearnPending = false
                let route = FlightDemoRouter.parseRoute(from: runState.prompt)
                runFlightDemoLearn(route: route)
            }
        }
        .onChange(of: engine.flightDemoReplayMatch) { _, match in
            guard let match else { return }
            engine.flightDemoReplayMatch = nil
            let route = FlightDemoRouter.parseRoute(from: runState.prompt)
            runFlightDemoReplay(route: route)
        }
    }

    // MARK: - Landing

    private var isOrchestratingThisTab: Bool {
        guard let tab = browserManager.currentTab(for: windowState) else { return false }
        return runState.activeTabId == tab.id
    }

    private var diaHome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 72)

            VStack(alignment: .leading, spacing: 28) {
                landingHeader
                    .landingRise(appeared: landingAppeared, delay: 0.0)
                promptBar
                    .landingRise(appeared: landingAppeared, delay: 0.07)
                landingFooter
                    .landingRise(appeared: landingAppeared, delay: 0.14)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 88)
        }
        .padding(.horizontal, 40)
    }

    private var landingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenHive")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.2)

            Text("What should we do?")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.primary)
                .tracking(-0.8)
        }
    }

    private var promptBar: some View {
        HStack(spacing: 10) {
            AgentModelPickerButton(selection: Binding(
                get: { runState.selectedAgentModel },
                set: { runState.setAgentModel($0) }
            ))

            Divider()
                .frame(height: 28)
                .opacity(0.35)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .onSubmit(submit)
            }

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .liquidGlassSurface(cornerRadius: 14, thickness: .thin)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: query.isEmpty)
    }

    private var landingFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                footerHint("Return", detail: "run task")
                footerDot
                footerHint("URL", detail: "opens in tab")
                if !engine.skills.isEmpty {
                    footerDot
                    Text("\(engine.skills.count) saved workflow\(engine.skills.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 12) {
                engineStatusChip
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() }
                } label: {
                    Label(showAdvanced ? "Less" : "Options", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showAdvanced {
                advancedControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var engineStatusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.engineReady ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 5, height: 5)
            if engine.engineReady {
                HStack(spacing: 5) {
                    AgentModelLogo(brand: runState.selectedAgentModel.brand, size: 14)
                    Text(runState.selectedAgentModel.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Engine offline")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func footerHint(_ key: String, detail: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var footerDot: some View {
        Text("·")
            .font(.system(size: 12))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 6)
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Toggle("Record workflow", isOn: $runState.isRecording)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Plan mode", isOn: $runState.planningModeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Background", isOn: $runState.backgroundModeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .font(.system(size: 12))

            Text(backgroundModeHint)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            MCPIntegrationsView()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 10, thickness: .thin)
    }

    private var backgroundModeHint: String {
        if runState.backgroundModeEnabled {
            return "Agent runs in this tab — switch tabs freely; live status stays in the notch."
        }
        if runState.isRecording {
            return "Compiles a skill when the run finishes."
        }
        return "Observation runs in the background."
    }

    private var matchingOverlay: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Matching workflow…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var runningOverlay: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(engine.executionProgress ?? "Running…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if tokens.currentRunTokens > 0 {
                Text("\(tokens.currentRunTokens) tokens")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button("Stop") {
                engine.cancelExecution()
                engine.cancelTrajectory()
                runState.phase = .idle
                runState.flightDemoMode = .none
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    private var flightLearningOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Learning flight workflow", systemImage: "brain.head.profile")
                        .font(.headline)
                    Text("Recording steps into MDP · run again for fast replay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                liveTaskClock
                Button("Stop") {
                    engine.cancelTrajectory()
                    runState.phase = .idle
                    runState.flightDemoMode = .none
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            stepLogPanelCompact
                .frame(maxHeight: 220)

            Spacer(minLength: 0)
        }
    }

    private var flightReplayOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("MDP replay", systemImage: "bolt.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(runState.skillName ?? FlightDemoRouter.skillName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                liveTaskClock
                if engine.isExecuting {
                    Button("Stop") {
                        engine.cancelExecution()
                        runState.phase = .idle
                        runState.flightDemoMode = .none
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            TaskRunView()
                .environmentObject(browserManager)
        }
    }

    private var liveTaskClock: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(formatElapsedMs(elapsedMs))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(runState.flightDemoMode == .replay ? .green : .orange)
        }
    }

    private var elapsedMs: Int {
        if tokens.currentRunElapsedMs > 0 { return tokens.currentRunElapsedMs }
        guard let start = runState.runStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private func formatElapsedMs(_ ms: Int) -> String {
        guard ms > 0 else { return "0.0s" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    private var stepLogPanelCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(runState.stepLog) { entry in
                        HStack(spacing: 6) {
                            Text("\(entry.index)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                    if runState.stepLog.isEmpty {
                        Text("Waiting for first step…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .openHiveGlassPanel()
        .padding(.horizontal, 16)
    }

    private var agentBackground: some View {
        ShaderGradientBackground(brand: runState.selectedAgentModel.brand)
            .opacity(landingAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.9), value: landingAppeared)
            .animation(.easeInOut(duration: 2.4), value: runState.selectedAgentModel.brand)
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if WorkflowSlashCommandExecutor.execute(trimmed, browserManager: browserManager) {
            query = ""
            return
        }

        // URL → normal navigation
        if looksLikeURL(trimmed) {
            guard let tab = browserManager.currentTab(for: windowState) else { return }
            tab.isOpenHiveNewTab = false
            query = ""
            tab.navigateToURL(trimmed)
            return
        }

        if runState.planningModeEnabled {
            guard let tab = browserManager.currentTab(for: windowState),
                  let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id)
            else {
                WorkflowManager.postToast("Could not prepare browser tab", isError: true)
                return
            }
            runState.prompt = trimmed
            runState.activeTabId = tab.id
            engine.startPlan(
                prompt: trimmed,
                webView: webView,
                tabId: tab.id,
                windowId: windowState.id,
                browserManager: browserManager
            )
            runState.phase = .planning
            return
        }

        // Flight demo: scripted trajectory (candidate-aware) — not brittle MDP label replay
        if FlightDemoRouter.isFlightPrompt(trimmed) {
            query = ""
            guard let tab = browserManager.currentTab(for: windowState) else { return }
            let route = FlightDemoRouter.parseRoute(from: trimmed)
            runState.prompt = trimmed
            runState.activeTabId = tab.id
            let hasSkill = FlightDemoRouter.hasLearnedSkill(for: route, in: engine.skills)
            if hasSkill {
                runFlightDemoReplay(route: route)
            } else {
                runFlightDemoLearn(route: route)
            }
            return
        }

        // Skill match first, then agent fallback
        query = ""
        guard let tab = browserManager.currentTab(for: windowState) else { return }
        runState.prompt = trimmed
        runState.beginMatching(prompt: trimmed, tabId: tab.id)
        engine.matchTask(prompt: trimmed)
    }

    private func runAgent() {
        guard let tab = browserManager.currentTab(for: windowState) else {
            WorkflowManager.postToast("No tab available", isError: true)
            return
        }

        if !engine.engineReady {
            WorkflowManager.postToast("Engine offline — run ./scripts/start_engine.sh", isError: true)
            return
        }

        guard let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id) else {
            WorkflowManager.postToast("Could not prepare browser tab", isError: true)
            return
        }

        runState.showSkillConfirm = false
        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        runState.beginRun(skillName: nil, skillId: nil, tabId: tab.id)
        AgentNotchViewModel.shared.open()
        AgentNotchPanelController.shared.show()
        engine.startAgentTask(
            goal: runState.prompt,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }

    private func confirmRunSkill() {
        guard let match = runState.pendingMatch,
              let tab = browserManager.currentTab(for: windowState),
              let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id)
        else { return }

        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        runState.beginRun(skillName: match.name, skillId: match.skillId, tabId: tab.id)
        AgentNotchViewModel.shared.open()
        engine.confirmRunSkill(
            skillId: match.skillId,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }

    private func runFlightDemoLearn(route: FlightRoute) {
        guard let tab = browserManager.currentTab(for: windowState) else {
            WorkflowManager.postToast("Could not prepare browser tab", isError: true)
            return
        }

        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        runState.showSkillConfirm = false
        runState.flightDemoMode = .learning
        runState.beginRun(skillName: FlightDemoRouter.displayName(for: route), skillId: route.skillId, tabId: tab.id)
        tokens.clearLiveRun()
        AgentNotchViewModel.shared.open()
        AgentNotchPanelController.shared.show()

        Task { @MainActor in
            guard let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id) else {
                WorkflowManager.postToast("Could not prepare browser tab", isError: true)
                return
            }
            await prepareFlightDemoPage(webView: webView)
            engine.startFlightDemoLearn(
                route: route,
                webView: webView,
                tabId: tab.id,
                windowId: windowState.id,
                browserManager: browserManager
            )
        }
    }

    private func runFlightDemoReplay(route: FlightRoute) {
        guard let tab = browserManager.currentTab(for: windowState) else { return }

        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        runState.showSkillConfirm = false
        runState.flightDemoMode = .replay
        runState.beginRun(
            skillName: FlightDemoRouter.displayName(for: route),
            skillId: route.skillId,
            tabId: tab.id
        )
        tokens.clearLiveRun()
        AgentNotchViewModel.shared.open()
        AgentNotchPanelController.shared.show()

        Task { @MainActor in
            guard let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id) else { return }
            await prepareFlightDemoPage(webView: webView)
            engine.startFlightDemoReplay(
                route: route,
                webView: webView,
                tabId: tab.id,
                windowId: windowState.id,
                browserManager: browserManager
            )
        }
    }

    /// Load Google Flights and wait until the search form is ready before scripted actions run.
    private func prepareFlightDemoPage(webView: WKWebView) async {
        let flightsURL = URL(string: FlightDemoRouter.startURL)!
        if webView.url?.absoluteString.contains("travel/flights") != true {
            webView.load(URLRequest(url: flightsURL))
        }

        var formReady = false
        for _ in 0..<60 {
            let url = webView.url?.absoluteString ?? ""
            if url.contains("travel/flights") {
                let hasForm = try? await webView.evaluateJavaScript(
                    "document.body && document.body.innerText.toLowerCase().includes('where from')"
                ) as? Bool
                if hasForm == true {
                    formReady = true
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        // Form already detected above; just a short tail for the SPA to settle.
        try? await Task.sleep(nanoseconds: (formReady ? 300 : 1_200) * 1_000_000)
        OpenHiveObservation.inject(into: webView)
        await OpenHiveObservation.installAgentAutomation(on: webView)
    }

    private func looksLikeURL(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return true }
        if t.contains(" ") { return false }
        return t.contains(".") && !t.hasPrefix("/")
    }
}

// MARK: - Dia-style rise animation

private struct LandingRiseModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 44)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .bottom)
            .animation(
                .spring(response: 0.72, dampingFraction: 0.84).delay(delay),
                value: appeared
            )
    }
}

private extension View {
    func landingRise(appeared: Bool, delay: Double) -> some View {
        modifier(LandingRiseModifier(appeared: appeared, delay: delay))
    }
}
