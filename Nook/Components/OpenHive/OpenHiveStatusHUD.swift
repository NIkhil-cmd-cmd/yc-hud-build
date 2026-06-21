//
//  OpenHiveStatusHUD.swift
//  Always-visible engine + step count overlay
//

import SwiftUI

struct OpenHiveStatusHUD: View {
    @Bindable var engine = EngineBridge.shared
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text("OpenHive")
                .font(.system(size: 11, weight: .semibold))
            if engine.observedStepCount > 0 {
                Text("\(engine.observedStepCount) steps")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !engine.workflows.isEmpty {
                Text("\(engine.workflows.count) wf")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let reward = engine.hudReward {
                Text(String(format: "HUD %.0f%%", reward * 100))
                    .font(.system(size: 10, design: .monospaced).weight(.bold))
                    .foregroundStyle(reward >= 0.75 ? .green : .orange)
            }
            Button("AI") {
                browserManager.toggleAISidebar(for: windowState)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .padding(12)
    }
}
