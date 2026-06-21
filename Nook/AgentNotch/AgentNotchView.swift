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
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
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
        HStack(spacing: 8) {
            if isActive {
                liveClockBadge
            }
            statusIndicator
            Text(primaryLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isActive {
                closedMetric("\(liveTokens)", icon: "sparkles")
                closedMetric(shortModel, icon: "cpu")
            } else {
                closedMetric(engine.engineReady ? shortModel : "offline", icon: "cpu")
            }
        }
        .padding(.horizontal, 12)
    }

    private var liveClockBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(formatElapsed(liveElapsedMs))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(runState.flightDemoMode == .replay ? Color.green : Color.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private var liveElapsedMs: Int {
        if tokens.currentRunElapsedMs > 0 { return tokens.currentRunElapsedMs }
        guard let start = runState.runStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private var openHeader: some View {
        HStack {
            if isActive {
                liveClockBadge
            }
            statusIndicator
            Text("OpenHive Agent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if engine.isExecuting {
                Button("Stop") {
                    engine.cancelExecution()
                    engine.cancelTrajectory()
                    runState.phase = .idle
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 4)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(runState.prompt.isEmpty ? "Ready for tasks" : runState.prompt)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(engine.executionProgress ?? statusSubtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 8) {
                statBlock("Tokens", value: "\(liveTokens)")
                statBlock("Model", value: shortModel)
                statBlock("Time", value: formatElapsed(tokens.currentRunElapsedMs))
                statBlock("Steps", value: "\(runState.stepLog.count)")
            }

            if !runState.stepLog.isEmpty {
                Divider().opacity(0.25)
                ForEach(runState.stepLog.suffix(5)) { entry in
                    HStack(spacing: 6) {
                        Text("\(entry.index)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 14, alignment: .trailing)
                        Text(entry.message)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.top, 4)
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
                    if vm.notchState == .open && !isActive {
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

    private var liveTokens: Int { tokens.currentRunTokens }

    private var shortModel: String {
        let m = runState.agentModel.isEmpty ? engine.agentModel : runState.agentModel
        if m.contains("gpt-4o-mini") { return "4o-mini" }
        if m.contains("gpt-4o") { return "gpt-4o" }
        return m.split(separator: "/").last.map(String.init) ?? m
    }

    private var primaryLabel: String {
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
        if isActive {
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

    private func closedMetric(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private func statBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatElapsed(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        if ms >= 1000 { return String(format: "%.1fs", Double(ms) / 1000) }
        return "\(ms)ms"
    }
}
