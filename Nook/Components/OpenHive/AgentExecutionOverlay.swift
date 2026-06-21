//
//  AgentExecutionOverlay.swift
//  OpenHive — dim overlay + element spotlight during agent/workflow runs
//

import SwiftUI

struct AgentExecutionOverlay: View {
    @Bindable private var agentState = AgentExecutionState.shared
    @Bindable private var engine = EngineBridge.shared

    var body: some View {
        if agentState.isActive || engine.isExecuting || engine.lastActionDescription != nil {
            ZStack {
                Color.black.opacity(0.25)
                    .allowsHitTesting(false)

                if let label = agentState.actionLabel ?? engine.lastActionDescription {
                    VStack {
                        Spacer()
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: agentState.actionLabel)
        }
    }
}
