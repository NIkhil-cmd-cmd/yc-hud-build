//
//  OpenHivePanelView.swift
//  OpenHive — workflows list + engine status in sidebar
//

import SwiftUI

struct OpenHivePanelView: View {
    @Bindable var engine = EngineBridge.shared
    @Bindable var workflows = WorkflowManager.shared
    @EnvironmentObject var browserManager: BrowserManager
    @State private var graphWorkflow: GraphSheetItem?
    @State private var showDeleteAllConfirmation = false

    private struct GraphSheetItem: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("OpenHive Engine")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if engine.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(engine.isConnected ? "Online" : "Offline")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            // Stats row
            HStack(spacing: 12) {
                statPill("\(engine.observedStepCount)", label: "steps")
                statPill(engine.isExecuting ? "T1" : "—", label: "tier")
                if let progress = engine.executionProgress {
                    statPill(progress, label: "run")
                }
            }
            .padding(.horizontal, 12)

            // Live action during execution
            if let action = engine.lastActionDescription {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(action)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
            }

            if let msg = workflows.compileMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            MetricsStripView()

            // Workflows
            if !engine.workflows.isEmpty {
                HStack {
                    Text("Workflows")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete All") {
                        showDeleteAllConfirmation = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(workflows.isExecuting || !engine.isConnected)
                    if engine.isExecuting {
                        Button("Cancel") {
                            WorkflowManager.shared.cancelExecution()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)

                ForEach(engine.workflows) { wf in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wf.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("\(wf.steps) steps")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            graphWorkflow = GraphSheetItem(id: wf.id)
                        } label: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("View policy graph")
                        Button("Run") {
                            runWorkflow(wf.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(workflows.isExecuting)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            } else if engine.isConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browse to record steps")
                        .font(.caption.weight(.medium))
                    Text("Run replays in the current tab")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Then: save this as my workflow")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
            } else {
                Text("Run ./scripts/start_engine.sh")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
            }

            if let reward = engine.hudReward {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(reward >= 0.75 ? .green : .orange)
                    Text(String(format: "HUD %.0f%%", reward * 100))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 12)
            }

            if let err = workflows.lastError ?? engine.connectionError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
        .openHiveGlassPanel()
        .padding(.horizontal, 8)
        .sheet(item: $graphWorkflow) { item in
            WorkflowGraphView(workflowId: item.id)
        }
        .confirmationDialog(
            "Delete all workflows?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                workflows.deleteAllWorkflows()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(engine.workflows.count) saved workflow\(engine.workflows.count == 1 ? "" : "s"). This cannot be undone.")
        }
    }

    private func statPill(_ value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func runWorkflow(_ id: String) {
        workflows.lastError = nil
        engine.connectionError = nil
        guard let tab = browserManager.currentTabForActiveWindow(),
              let windowId = browserManager.windowRegistry?.activeWindow?.id,
              let webView = browserManager.getWebView(for: tab.id, in: windowId)
        else {
            workflows.lastError = "Select a tab first"
            return
        }
        tab.isOpenHiveNewTab = false
        WorkflowManager.shared.execute(workflowId: id, webView: webView)
    }
}
