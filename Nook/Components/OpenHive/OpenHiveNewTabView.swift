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
                }

                WorkflowsPanelView(style: .full)
                    .frame(maxWidth: 440)

                Text("⌘L focus bar · /save · /run · /help")
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

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let tab = browserManager.currentTab(for: windowState) else { return }

        if WorkflowSlashCommandExecutor.execute(trimmed, browserManager: browserManager) {
            query = ""
            return
        }

        tab.isOpenHiveNewTab = false
        query = ""
        tab.navigateToURL(trimmed)
    }
}
