//
//  MetricsStripView.swift
//  OpenHive — live run metrics during workflow execution
//

import SwiftUI

struct MetricsStripView: View {
    @Bindable var tokens = TokenDashboardManager.shared
    @Bindable var engine = EngineBridge.shared

    var body: some View {
        if engine.isExecuting || tokens.currentRunElapsedMs > 0 || engine.hudReward != nil {
            HStack(spacing: 12) {
                if let reward = engine.hudReward ?? tokens.currentRunReward {
                    hudBadge(reward)
                }
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

    private func hudBadge(_ reward: Double) -> some View {
        let pct = Int(reward * 100)
        let color: Color = reward >= 0.75 ? .green : (reward >= 0.5 ? .orange : .red)
        return Text("HUD \(pct)%")
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
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
