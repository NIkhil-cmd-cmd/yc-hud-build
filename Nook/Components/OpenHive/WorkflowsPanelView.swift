//
//  WorkflowsPanelView.swift
//  Nook — save, list, and run recorded workflows
//

import SwiftUI

struct WorkflowsPanelView: View {
    enum Style {
        case full
        case compact
    }

    var style: Style = .full
    @Bindable var engine = EngineBridge.shared
    @Bindable var workflows = WorkflowManager.shared
    @EnvironmentObject var browserManager: BrowserManager
    @State private var saveName = ""
    @State private var slashInput = ""
    @State private var graphWorkflow: GraphSheetItem?
    @State private var showDeleteAllConfirmation = false

    private struct GraphSheetItem: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .full ? 14 : 10) {
            header
            saveRow
            if let msg = workflows.compileMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            workflowList
            if let err = workflows.lastError ?? engine.connectionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Text("/save · /run · /workflows · /help")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            slashCommandField
        }
        .padding(style == .full ? 16 : 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
        }
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
            Text("Removes \(engine.workflows.count) saved workflow\(engine.workflows.count == 1 ? "" : "s").")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text("Workflows")
                .font(.system(size: style == .full ? 15 : 13, weight: .semibold))
            Spacer()
            if engine.isExecuting {
                ProgressView().controlSize(.small)
            }
            Text("\(engine.observedStepCount) steps")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            TextField("Name this workflow…", text: $saveName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(saveWorkflow)
            Button("Save", action: saveWorkflow)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty || !engine.isConnected || engine.isExecuting)
        }
    }

    @ViewBuilder
    private var workflowList: some View {
        if engine.workflows.isEmpty {
            Text(engine.isConnected
                ? "Browse to record steps, then save."
                : "Start the engine: ./scripts/start_engine.sh")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text("Saved")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if engine.isExecuting {
                        Button("Cancel") { workflows.cancelExecution() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                    Button("Delete all") { showDeleteAllConfirmation = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(workflows.isExecuting || !engine.isConnected)
                }
                ForEach(engine.workflows) { wf in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wf.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("\(wf.steps) steps")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            graphWorkflow = GraphSheetItem(id: wf.id)
                        } label: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("View MDP graph")
                        Button("Run") { runWorkflow(wf.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(workflows.isExecuting)
                    }
                }
            }
        }
    }

    private var slashCommandField: some View {
        HStack(spacing: 6) {
            TextField("/save notion", text: $slashInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(runSlashCommand)
            Button("Go", action: runSlashCommand)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(slashInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func runSlashCommand() {
        let cmd = slashInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        _ = WorkflowSlashCommandExecutor.execute(cmd, browserManager: browserManager)
        slashInput = ""
    }

    private func saveWorkflow() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        workflows.saveCurrentSession(name: name)
        saveName = ""
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
        WorkflowManager.shared.execute(
            workflowId: id,
            webView: webView,
            tabId: tab.id,
            windowId: windowId,
            browserManager: browserManager
        )
    }
}
