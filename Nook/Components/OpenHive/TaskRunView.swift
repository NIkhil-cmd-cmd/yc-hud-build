//
//  TaskRunView.swift
//  OpenHive — live MDP graph + step log during execution
//

import SwiftUI
import WebKit

struct TaskRunView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Bindable private var engine = EngineBridge.shared
    @Bindable private var runState = TaskRunState.shared

    @State private var mdpGraph: WorkflowMDPGraph?
    @State private var showBenchmark = false
    @State private var benchmark = HUDBenchmarkResult()

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 360)
            stepLogPanel
                .frame(minWidth: 240, idealWidth: 280)
        }
        .padding(12)
        .onAppear { loadMDPGraph() }
        .onChange(of: runState.skillId) { _, _ in loadMDPGraph() }
        .sheet(isPresented: $showBenchmark) {
            HUDBenchmarkView(benchmark: benchmark)
                .padding()
        }
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            if !runState.subtasks.isEmpty {
                subtaskChecklist
            }

            if let graph = mdpGraph {
                WorkflowMDPInteractiveView(graph: graph, liveStateId: runState.liveStateId)
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No MDP graph",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Graph loads when a skill is matched.")
                )
            }

            if runState.phase == .complete {
                Button("Compare with HUD browser") {
                    benchmark = HUDBenchmarkResult(isRunning: true, phase: "Starting…")
                    showBenchmark = true
                    engine.startHUDBenchmark(prompt: runState.prompt, skillId: runState.skillId)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(runState.skillName ?? "Running task")
                    .font(.headline)
                Text(engine.executionProgress ?? "Executing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runState.flightDemoMode == .replay {
                Text(formatElapsed(runState))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.green)
            }
            if engine.isExecuting {
                Button("Cancel") { engine.cancelExecution() }
                    .controlSize(.small)
            }
        }
    }

    private func formatElapsed(_ runState: TaskRunState) -> String {
        let ms = TokenDashboardManager.shared.currentRunElapsedMs
        if ms <= 0, let start = runState.runStartedAt {
            return String(format: "%.1fs", Date().timeIntervalSince(start))
        }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    private var subtaskChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(runState.subtasks) { subtask in
                HStack(spacing: 8) {
                    Image(systemName: subtask.status == "done" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(subtask.status == "done" ? Color.green : Color.secondary)
                    Text(subtask.description)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stepLogPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(runState.stepLog) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(entry.index)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                            Text(entry.message)
                                .font(.caption)
                        }
                    }
                    if runState.stepLog.isEmpty {
                        Text("Waiting for first step…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .openHiveGlassPanel()
    }

    private func loadMDPGraph() {
        guard let skillId = runState.skillId else { return }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/mdps/\(skillId).json")
        let workflow = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/workflows/\(skillId).json")
        let url = FileManager.default.fileExists(atPath: support.path) ? support : workflow
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if case .success(let graph) = WorkflowMDPParser.parse(json: json, workflowId: skillId) {
            mdpGraph = graph
        }
    }
}
