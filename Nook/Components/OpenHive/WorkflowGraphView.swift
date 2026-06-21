//
//  WorkflowGraphView.swift
//  OpenHive — workflow timeline + interactive MDP policy graph
//

import SwiftUI

struct WorkflowGraphView: View {
    let workflowId: String

    @State private var workflowName = ""
    @State private var steps: [WorkflowStep] = []
    @State private var mdpGraph: WorkflowMDPGraph?
    @State private var loadError: String?
    @State private var selectedTab: ViewTab = .mdp

    enum ViewTab: String, CaseIterable, Identifiable {
        case mdp = "MDP Graph"
        case timeline = "Timeline"

        var id: String { rawValue }
    }

    struct WorkflowStep: Identifiable {
        let id: Int
        let type: String
        let title: String
        let subtitle: String
        let icon: String
        let tint: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let loadError {
                errorCard(loadError)
                    .padding(20)
                Spacer()
            } else if mdpGraph == nil && steps.isEmpty {
                ProgressView("Loading workflow…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("View", selection: $selectedTab) {
                    ForEach(ViewTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                switch selectedTab {
                case .mdp:
                    if let mdpGraph {
                        WorkflowMDPInteractiveView(graph: mdpGraph)
                    } else {
                        Text("No MDP policy data for this workflow.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .timeline:
                    ScrollView {
                        timelineContent
                            .padding(20)
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadGraph() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(workflowName.isEmpty ? workflowId : workflowName)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    if let mdp = mdpGraph {
                        Text("\(mdp.states.count) states · \(mdp.edges.count) edges")
                    }
                    if !steps.isEmpty {
                        Text("\(steps.count) recorded step\(steps.count == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded demonstration trace")
                .font(.headline)
            if steps.isEmpty {
                Text("No linear action list — open MDP Graph to explore the policy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            ZStack {
                                Circle()
                                    .fill(step.tint.opacity(0.18))
                                    .frame(width: 34, height: 34)
                                Image(systemName: step.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(step.tint)
                            }
                            if index < steps.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 2, height: 28)
                                    .padding(.vertical, 4)
                            }
                        }
                        .frame(width: 34)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Step \(step.id + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(step.type.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(step.tint.opacity(0.14), in: Capsule())
                                    .foregroundStyle(step.tint)
                            }
                            Text(step.title)
                                .font(.system(size: 14, weight: .semibold))
                            if !step.subtitle.isEmpty {
                                Text(step.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadGraph() {
        switch WorkflowMDPParser.load(workflowId: workflowId) {
        case .success(let graph):
            mdpGraph = graph
            workflowName = graph.workflowName
            loadError = nil
        case .failure(let error):
            mdpGraph = nil
            loadError = error.localizedDescription
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/workflows/\(workflowId).json")
        guard let data = try? Data(contentsOf: support),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if workflowName.isEmpty {
            workflowName = json["name"] as? String ?? workflowId
        }
        let rawActions = (json["actions"] as? [[String: Any]]) ?? actionsFromPolicy(json)
        steps = rawActions.enumerated().map { index, action in
            makeStep(index: index, action: action)
        }
    }

    private func actionsFromPolicy(_ json: [String: Any]) -> [[String: Any]] {
        guard let policy = json["policy"] as? [String: [String: Any]], !policy.isEmpty else { return [] }
        let start: String
        if let numericStart = policy.keys.compactMap({ Int($0) }).sorted().first {
            start = String(numericStart)
        } else {
            start = policy.keys.sorted().first ?? ""
        }
        guard !start.isEmpty else { return [] }

        var actions: [[String: Any]] = []
        var seen = Set<String>()
        var current: String? = start
        while let id = current, !seen.contains(id), let entry = policy[id] {
            seen.insert(id)
            if let action = entry["action"] as? [String: Any], action["type"] != nil {
                actions.append(action)
            }
            let nextRaw = entry["next"]
            let next: String? = {
                if let n = nextRaw as? Int { return String(n) }
                if let n = nextRaw as? String, !n.isEmpty { return n }
                return nil
            }()
            current = next.flatMap { policy[$0] != nil ? $0 : nil }
        }
        return actions
    }

    private func makeStep(index: Int, action: [String: Any]) -> WorkflowStep {
        let type = (action["type"] as? String ?? "unknown").lowercased()
        return WorkflowStep(
            id: index,
            type: type,
            title: stepLabel(for: action),
            subtitle: stepSubtitle(for: action),
            icon: icon(for: type),
            tint: tint(for: type)
        )
    }

    private func stepLabel(for action: [String: Any]) -> String {
        let type = (action["type"] as? String ?? "step").capitalized
        switch action["type"] as? String {
        case "navigate":
            if let url = action["url"] as? String, let host = URL(string: url)?.host {
                return "Go to \(host)"
            }
            return action["url"] as? String ?? "Navigate"
        case "click":
            let text = cleaned(action["text"] as? String)
            if !text.isEmpty { return "Click “\(truncate(text, 72))”" }
            return "Click element"
        case "type", "fill":
            let value = cleaned(action["value"] as? String ?? action["text"] as? String)
            if !value.isEmpty { return "Type “\(truncate(value, 72))”" }
            return "Type into field"
        default:
            return type
        }
    }

    private func stepSubtitle(for action: [String: Any]) -> String {
        switch action["type"] as? String {
        case "navigate": return action["url"] as? String ?? ""
        case "click", "type", "fill":
            return cleaned(action["selector"] as? String)
        default: return ""
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "navigate": return "safari"
        case "click": return "hand.tap"
        case "type", "fill": return "keyboard"
        default: return "circle"
        }
    }

    private func tint(for type: String) -> Color {
        switch type {
        case "navigate": return .blue
        case "click": return .orange
        case "type", "fill": return .green
        default: return .secondary
        }
    }

    private func cleaned(_ value: String?) -> String {
        value?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func truncate(_ value: String, _ max: Int) -> String {
        WorkflowMDPParser.truncate(value, max)
    }
}
