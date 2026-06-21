//
//  AgentNotchView.swift
//  OpenHive — boring.notch ContentView notch section (agent metrics)
//

import SwiftUI

@MainActor
struct AgentNotchView: View {
    @Bindable var vm: AgentNotchViewModel
    @Bindable var runState = TaskRunState.shared
    @Bindable var engine = EngineBridge.shared
    @Bindable var tokens = TokenDashboardManager.shared
    @Bindable var voice = VoiceInputManager.shared

    @State private var hoverTask: Task<Void, Never>?

    private let animationSpring = Animation.interactiveSpring(
        response: 0.38, dampingFraction: 0.8, blendDuration: 0
    )

    private var topCornerRadius: CGFloat {
        vm.notchState == .open
            ? NotchSizing.cornerRadiusInsets.opened.top
            : NotchSizing.cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        vm.notchState == .open
            ? NotchSizing.cornerRadiusInsets.opened.bottom
            : NotchSizing.cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                notchLayout
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                            ? NotchSizing.cornerRadiusInsets.opened.top
                            : NotchSizing.cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 8 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(color: vm.notchState == .open ? .black.opacity(0.7) : .clear, radius: 6)
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .animation(
                        vm.notchState == .open
                            ? Animation.spring(response: 0.42, dampingFraction: 0.8)
                            : Animation.spring(response: 0.45, dampingFraction: 1.0),
                        value: vm.notchState
                    )
                    .contentShape(Rectangle())
                    .onHover { handleHover($0) }
                    .onTapGesture { doOpen() }
            }
            .padding(.bottom, 8)
        }
        .frame(
            maxWidth: NotchSizing.windowSize.width,
            maxHeight: NotchSizing.windowSize.height,
            alignment: .top
        )
        .compositingGroup()
        .preferredColorScheme(.dark)
        .onChange(of: engine.isExecuting) { _, executing in
            if executing { doOpen() }
        }
        .onChange(of: runState.phase) { _, phase in
            if phase == .running || phase == .planning { doOpen() }
        }
        .onChange(of: voice.isListening) { _, listening in
            if listening { doOpen() }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.notchState == .open {
                openHeader
                    .frame(height: max(24, vm.effectiveClosedNotchHeight))
            } else {
                closedBar
                    .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
            }

            if vm.notchState == .open {
                expandedContent
                    .transition(
                        .scale(scale: 0.92, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.35))
                    )
            }
        }
    }

    private var closedBar: some View {
        HStack(spacing: 6) {
            statusIndicator
            Text(primaryLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isActive {
                closedStatPill(formatElapsed(liveElapsedMs))
                closedStatPill("\(liveTokens)tk")
                closedStatPill(stepProgressLabel)
                if let stateId = runState.liveStateId ?? runState.mdpStateId {
                    closedStatPill("S\(stateId)")
                }
            } else {
                closedStatPill(engine.engineReady ? shortModel : "off")
            }
        }
        .padding(.horizontal, 10)
    }

    private var liveClockBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(formatElapsed(liveElapsedMs))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(runState.flightDemoMode == .replay ? Color.green : Color.orange)
        }
    }

    private var liveElapsedMs: Int {
        if tokens.currentRunElapsedMs > 0 { return tokens.currentRunElapsedMs }
        guard let start = runState.runStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private var openHeader: some View {
        HStack(spacing: 6) {
            statusIndicator
            Text(primaryLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            if runState.backgroundModeEnabled, isActive {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if isActive {
                liveClockBadge
            }
            if engine.isExecuting {
                Button {
                    engine.cancelExecution()
                    engine.cancelTrajectory()
                    runState.phase = .idle
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if isListening {
            listeningContent
        } else {
            runContent
        }
    }

    private var listeningContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: 0.4 + 0.6 * CGFloat((i % 3) + 1) / 3, anchor: .center)
                        .symbolEffect(.pulse, options: .repeating)
                }
                .frame(height: 12)
                Text("Speak your command")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
            .frame(height: 14)

            Text(voice.transcript.isEmpty ? "…" : voice.transcript)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(voice.transcript.isEmpty ? 0.3 : 0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.2), value: voice.transcript)
        }
        .padding(.top, 2)
    }

    private var runContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            statsRow

            ZStack(alignment: .leading) {
                if let entry = latestLogEntry {
                    logLine(entry)
                        .id(entry.id)
                        .transition(logTransition)
                } else if let progress = engine.executionProgress {
                    Text(progress)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .id("progress-\(progress)")
                        .transition(logTransition)
                } else {
                    Text(statusSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .id("idle")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            .clipped()
            .animation(.smooth(duration: 0.32), value: latestLogEntry?.id)
            .animation(.smooth(duration: 0.32), value: engine.executionProgress)
        }
        .padding(.top, 2)
    }

    private var statsRow: some View {
        HStack(spacing: 4) {
            statPill("tk", value: "\(liveTokens)")
            statPill("t", value: formatElapsed(liveElapsedMs))
            statPill("step", value: stepProgressLabel)
            if let stateId = runState.liveStateId ?? runState.mdpStateId {
                statPill("S", value: stateId)
            }
            statPill("L", value: "\(tokens.currentRunTier)")
            statPill("mdl", value: shortModel)
            if let reward = tokens.currentRunReward {
                statPill("rw", value: String(format: "%.2f", reward))
            }
        }
    }

    private var latestLogEntry: TaskStepLogEntry? {
        runState.stepLog.last
    }

    private var stepProgressLabel: String {
        if let progress = engine.executionProgress,
           let match = progress.range(of: #"\d+/\d+"#, options: .regularExpression) {
            return String(progress[match])
        }
        return "\(runState.stepLog.count)"
    }

    private var logTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    private func logLine(_ entry: TaskStepLogEntry) -> some View {
        HStack(spacing: 5) {
            Text("\(entry.index)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
            Text(entry.message)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
    }
    // MARK: - Hover (boring.notch handleHover)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            withAnimation(animationSpring) { vm.isHovering = true }
            if vm.notchState == .closed {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, vm.isHovering, vm.notchState == .closed else { return }
                    await MainActor.run { doOpen() }
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(animationSpring) { vm.isHovering = false }
                    if vm.notchState == .open && !isActive && !isListening {
                        vm.close()
                    }
                }
            }
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) { vm.open() }
    }

    // MARK: - Helpers

    private var isActive: Bool {
        engine.isExecuting || runState.phase == .running || runState.phase == .planning
    }

    private var isListening: Bool { voice.isListening }

    private var liveTokens: Int { tokens.currentRunTokens }

    private var shortModel: String {
        let m = runState.agentModel.isEmpty ? engine.agentModel : runState.agentModel
        if m.contains("gpt-4o-mini") { return "4o-mini" }
        if m.contains("gpt-4o") { return "gpt-4o" }
        return m.split(separator: "/").last.map(String.init) ?? m
    }

    private var primaryLabel: String {
        if isListening { return "Listening…" }
        if !engine.engineReady { return "Engine starting…" }
        if isActive {
            if runState.flightDemoMode == .learning { return "Learning flight…" }
            if runState.flightDemoMode == .replay { return "MDP replay" }
            return runState.skillName ?? "Running"
        }
        if runState.phase == .complete { return "Done" }
        return "OpenHive"
    }

    private var statusSubtitle: String {
        engine.inTabAgentEnabled ? "in-tab agent · snapshot/@ref" : "agent offline"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isListening {
            Image(systemName: "mic.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        } else if isActive {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .symbolEffect(.pulse, options: .repeating)
        } else {
            Circle()
                .fill(engine.engineReady ? Color.green.opacity(0.75) : Color.orange)
                .frame(width: 6, height: 6)
        }
    }

    private func closedStatPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
    }

    private func statPill(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private func formatElapsed(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        if ms >= 1000 { return String(format: "%.1fs", Double(ms) / 1000) }
        return "\(ms)ms"
    }
}
