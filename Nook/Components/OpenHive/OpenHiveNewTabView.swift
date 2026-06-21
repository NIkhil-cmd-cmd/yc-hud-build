//
//  OpenHiveNewTabView.swift
//  Nook — new tab with search + workflows
//

import SwiftUI

struct OpenHiveNewTabView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var query = ""
    @State private var planModeEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 48)

                VStack(spacing: 16) {
                    Text("Nook")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))

                    TextField("Search or enter address", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular))
                        .multilineTextAlignment(.center)
                        .focused($isFocused)
                        .onSubmit(submit)
                        .frame(maxWidth: 440)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                                }
                        }

                    planModeControl
                }

                WorkflowsPanelView(style: .full)
                    .frame(maxWidth: 440)

                Text("⌘L focus bar · /save · /run · /agent · /help")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(newTabBackground)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
    }

    private var newTabBackground: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.35 : 0.5)
    }

    private var planModeControl: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    planModeEnabled.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Plan mode")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(planModeEnabled ? Color.cyan : Color.primary.opacity(0.72))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(planModeEnabled ? Color.cyan.opacity(0.15) : Color.primary.opacity(0.06))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(planModeEnabled ? Color.cyan.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 1)
                        }
                }
            }
            .buttonStyle(.plain)
            .help("Break this goal into subtasks and use workflows when relevant")

            if planModeEnabled {
                Text("Plans tasks, uses matching workflows, falls back to the agent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let tab = browserManager.currentTab(for: windowState) else { return }

        if WorkflowSlashCommandExecutor.execute(trimmed, browserManager: browserManager) {
            query = ""
            return
        }

        if planModeEnabled {
            startPlan(goal: trimmed, tab: tab)
            return
        }

        tab.isOpenHiveNewTab = false
        query = ""
        tab.navigateToURL(trimmed)
    }

    private func startPlan(goal: String, tab: Tab) {
        let workflows = WorkflowManager.shared
        let engine = EngineBridge.shared

        guard engine.isConnected else {
            workflows.lastError = "Engine offline — run ./scripts/start_engine.sh"
            return
        }
        guard let webView = browserManager.getWebView(for: tab.id, in: windowState.id) else {
            workflows.lastError = "Select a tab first"
            return
        }

        tab.isOpenHiveNewTab = false
        query = ""
        workflows.compileMessage = "Plan running: \(goal.prefix(60))…"
        engine.startUltraplanTask(
            goal: goal,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }
}
