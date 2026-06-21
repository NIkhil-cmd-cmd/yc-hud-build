//
//  MetricsStripView.swift
//  OpenHive — live run metrics during workflow execution
//

import SwiftUI

struct MetricsStripView: View {
    @Bindable var tokens = TokenDashboardManager.shared
    @Bindable var engine = EngineBridge.shared

    var body: some View {
        if engine.isExecuting || tokens.currentRunElapsedMs > 0 {
            HStack(spacing: 12) {
                Text("\(tokens.currentRunTokens) tokens")
                Text(formatMs(tokens.currentRunElapsedMs))
                tierBadge(tokens.currentRunTier)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func tierBadge(_ tier: Int) -> some View {
        let label = "T\(tier)"
        let color: Color = tier == 1 ? .green : (tier == 2 ? .orange : .red)
        return Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(color)
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
