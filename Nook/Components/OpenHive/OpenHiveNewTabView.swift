//
//  OpenHiveNewTabView.swift
//  New tab search — works offline via normal URL routing; Exa when engine up
//

import SwiftUI

struct OpenHiveNewTabView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Bindable private var engine = EngineBridge.shared
    @State private var query = ""
    @State private var isSearching = false
    @State private var answer = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("OpenHive")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Search or enter a URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("google.com/flights or ask anything...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit { submit() }

                Button(action: submit) {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 22))
                    }
                }
                .buttonStyle(.plain)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 6) {
                Circle().fill(engine.isConnected ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(engine.isConnected ? "Engine connected — Exa available" : "Engine offline — using web search")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .openHiveGlassPanel()
            }

            HStack(spacing: 12) {
                modelChip("Policy T1", detail: "0 tokens")
                modelChip("Fireworks T2", detail: "fallback")
                modelChip("MiniMax T3", detail: "emergency")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.3))
    }

    private func modelChip(_ title: String, detail: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Always navigate immediately — never block on engine WebSocket
        navigateSearch(trimmed)

        // Optional Exa answer overlay when engine is connected (non-blocking)
        guard engine.isConnected, !looksLikeURL(trimmed) else { return }
        isSearching = true
        errorMessage = nil
        EngineBridge.shared.exaSearch(query: trimmed, timeoutSeconds: 8) { result in
            isSearching = false
            if case .success(let text) = result, !text.isEmpty {
                answer = text
            }
        }
    }

    private func looksLikeURL(_ text: String) -> Bool {
        text.contains("://") || (text.contains(".") && !text.contains(" "))
    }

    private func navigateSearch(_ text: String) {
        guard let tab = browserManager.currentTab(for: windowState) else { return }
        tab.isOpenHiveNewTab = false
        answer = ""
        tab.navigateToURL(text)
        OpenHiveLogger.log("NewTab", "navigate", data: ["query": text])
    }
}
