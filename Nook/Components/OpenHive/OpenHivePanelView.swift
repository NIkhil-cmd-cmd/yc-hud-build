//
//  OpenHivePanelView.swift
//  OpenHive — workflows list + engine status in sidebar
//

import SwiftUI

struct OpenHivePanelView: View {
    @Bindable var engine = EngineBridge.shared
    @Bindable var workflows = WorkflowManager.shared
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OpenHive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(engine.isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)

            if let msg = workflows.compileMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            if engine.observedStepCount > 0 {
                Text("\(engine.observedStepCount) steps captured")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }

            MetricsStripView()

            if !engine.workflows.isEmpty {
                Text("Workflows")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                ForEach(engine.workflows) { wf in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wf.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text("\(wf.steps) steps")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run") {
                            runWorkflow(wf.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            if let err = engine.connectionError ?? workflows.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }

    private func runWorkflow(_ id: String) {
        guard let tab = browserManager.currentTabForActiveWindow(),
              let windowId = browserManager.windowRegistry?.activeWindow?.id,
              let webView = browserManager.getWebView(for: tab.id, in: windowId)
        else { return }
        WorkflowManager.shared.execute(workflowId: id, webView: webView)
    }
}
