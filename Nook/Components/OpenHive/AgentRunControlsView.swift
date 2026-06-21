//
//  AgentRunControlsView.swift
//  OpenHive — Pause / Stop during agent or workflow execution (Comet pattern)
//

import SwiftUI

struct AgentRunControlsView: View {
    @Bindable private var workflows = WorkflowManager.shared
    @Bindable private var engine = EngineBridge.shared
    @Bindable private var agentState = AgentExecutionState.shared
    @Environment(AIService.self) private var aiService

    private var isRunning: Bool {
        workflows.isExecuting || engine.isExecuting || aiService.isExecutingTools
    }

    var body: some View {
        if isRunning {
            HStack(spacing: 10) {
                Button {
                    if agentState.isPaused {
                        agentState.resume()
                    } else {
                        agentState.pause()
                    }
                } label: {
                    Label(agentState.isPaused ? "Resume" : "Pause", systemImage: agentState.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    workflows.cancelExecution()
                    agentState.end()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }
}
