//
//  WorkflowsSidebarSection.swift
//  OpenHive — Dia Skills-style workflow list in AI panel bottom
//

import SwiftUI
import WebKit

struct WorkflowsSidebarSection: View {
    @Bindable private var engine = EngineBridge.shared
    @Bindable private var workflows = WorkflowManager.shared
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var graphWorkflow: GraphSheetItem?

    private struct GraphSheetItem: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                Text("Workflows")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if engine.isConnected {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(.secondary)

            if engine.workflows.isEmpty {
                Text("Complete a task, then save it as a workflow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(engine.workflows) { wf in
                            workflowRow(wf)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            if let msg = workflows.compileMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .sheet(item: $graphWorkflow) { item in
            WorkflowGraphView(workflowId: item.id)
        }
        .onAppear {
            engine.refreshWorkflows()
        }
    }

    private func workflowRow(_ wf: EngineBridge.WorkflowSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                graphWorkflow = GraphSheetItem(id: wf.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wf.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(wf.steps) steps")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                graphWorkflow = GraphSheetItem(id: wf.id)
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("View MDP")

            Button("Run") {
                runWorkflow(wf)
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(workflows.isExecuting)
        }
    }

    private func runWorkflow(_ wf: EngineBridge.WorkflowSummary) {
        guard let tab = browserManager.currentTab(for: windowState),
              let webView = tab.assignedWebView else { return }
        AgentExecutionState.shared.begin(label: "Running \(wf.name)", tier: 1)
        workflows.execute(
            workflowId: wf.id,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }
}

struct SaveWorkflowPromptBanner: View {
    let suggestedName: String
    let onSave: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save as workflow?")
                .font(.system(size: 12, weight: .semibold))
            Text("\"\(suggestedName)\"")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
    }
}
