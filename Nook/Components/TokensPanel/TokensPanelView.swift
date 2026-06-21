//
//  TokensPanelView.swift
//  OpenHive — full token dashboard (Cmd+Shift+T)
//

import SwiftUI

struct TokensPanelView: View {
    @Bindable var tokens = TokenDashboardManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tokens")
                .font(.title2.weight(.semibold))

            HStack(spacing: 24) {
                metricColumn("Session", value: tokens.sessionTotal)
                metricColumn("Today", value: tokens.todayTotal)
                metricColumn("All time", value: tokens.allTimeTotal)
            }

            tierBreakdown

            if !tokens.recentRuns.isEmpty {
                Text("Recent runs")
                    .font(.headline)
                ForEach(tokens.recentRuns.prefix(10)) { run in
                    HStack {
                        Text(run.workflowName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(run.tokens) tok")
                            .font(.system(.caption, design: .monospaced))
                        Text(formatMs(run.elapsedMs))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 400)
        .onAppear { tokens.refresh() }
    }

    private func metricColumn(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
        }
    }

    private var tierBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By tier")
                .font(.headline)
            tierRow(tier: 1, label: "Policy (T1)", color: .green)
            tierRow(tier: 2, label: "Fireworks (T2)", color: .orange)
            tierRow(tier: 3, label: "MiniMax (T3)", color: .red)
        }
    }

    private func tierRow(tier: Int, label: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("\(tokens.byTier[tier, default: 0])")
                .font(.system(.subheadline, design: .monospaced))
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    TokensPanelView()
}
