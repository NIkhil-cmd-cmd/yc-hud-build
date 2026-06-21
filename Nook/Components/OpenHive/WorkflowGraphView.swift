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
    @State private var selectedTab: ViewTab = .graph
    @State private var selectedStateId: String?
    @State private var selectedClusterId: Int?

    enum ViewTab: String, CaseIterable, Identifiable {
        case graph = "MDP Graph"
        case buckets = "Similar Buckets"
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
                TabView(selection: $selectedTab) {
                    graphTab
                        .tabItem {
                            Label("MDP Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .tag(ViewTab.graph)

                    bucketsTab
                        .tabItem {
                            Label("Similar Buckets", systemImage: "magnifyingglass")
                        }
                        .tag(ViewTab.buckets)

                    ScrollView {
                        timelineContent
                            .padding(20)
                    }
                    .tabItem {
                        Label("Timeline", systemImage: "list.bullet.rectangle")
                    }
                    .tag(ViewTab.timeline)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadGraph() }
    }

    private var graphTab: some View {
        Group {
            if let mdpGraph {
                WorkflowMDPInteractiveView(
                    graph: mdpGraph,
                    selectedStateId: $selectedStateId,
                    selectedClusterId: $selectedClusterId
                )
            } else {
                Text("No MDP policy data for this workflow.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var bucketsTab: some View {
        Group {
            if let mdpGraph {
                WorkflowMDPBucketSearchView(
                    graph: mdpGraph,
                    selectedStateId: $selectedStateId,
                    selectedClusterId: $selectedClusterId,
                    selectedTab: $selectedTab
                )
            } else {
                Text("No MDP buckets to search yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            selectedStateId = graph.path.first ?? graph.states.first?.id
            selectedClusterId = selectedStateId.flatMap { graph.stateMap[$0]?.cluster?.id }
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

    private func truncate(_ value: String, _ maxLength: Int) -> String {
        WorkflowMDPParser.truncate(value, maxLength)
    }
}

struct WorkflowMDPBucketSearchView: View {
    let graph: WorkflowMDPGraph
    @Binding var selectedStateId: String?
    @Binding var selectedClusterId: Int?
    @Binding var selectedTab: WorkflowGraphView.ViewTab

    @State private var query = ""

    private var buckets: [MDPClusterInfo] {
        graph.buckets.sorted { lhs, rhs in
            if lhs.members != rhs.members { return lhs.members > rhs.members }
            return lhs.id < rhs.id
        }
    }

    private var filteredBuckets: [(bucket: MDPClusterInfo, score: Double)] {
        buckets
            .map { bucket in (bucket, similarityScore(for: bucket, query: query)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.bucket.members != rhs.bucket.members { return lhs.bucket.members > rhs.bucket.members }
                return lhs.bucket.id < rhs.bucket.id
            }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search buckets, URLs, actions, or element text", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                HStack(spacing: 10) {
                    Text("\(filteredBuckets.count) buckets")
                    if let selectedClusterId {
                        Text("Selected bucket \(selectedClusterId)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredBuckets, id: \.bucket.id) { item in
                            bucketCard(item.bucket, score: item.score)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(16)
            .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Search Guidance")
                    .font(.headline)
                Text("This view ranks MDP buckets by the current query and gives you a focused way to jump back into the graph tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let selectedCluster = currentSelectedBucket {
                    bucketDetails(selectedCluster)
                } else {
                    Text("Pick a bucket to inspect its actions and launch the graph view.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var currentSelectedBucket: MDPClusterInfo? {
        if let selectedClusterId {
            return graph.buckets.first(where: { $0.id == selectedClusterId })
        }
        return filteredBuckets.first?.bucket
    }

    private func bucketCard(_ bucket: MDPClusterInfo, score: Double) -> some View {
        let isSelected = selectedClusterId == bucket.id
        return Button {
            select(bucket: bucket)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bucket \(bucket.id)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(scoreLabel(score))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Text(bucket.urlPattern)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(bucket.members) states")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let action = bucket.actions.first {
                        Text(action.label)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if !bucket.actions.isEmpty {
                    bucketTagRow(bucket.actions.prefix(3).map(\.label))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func bucketDetails(_ bucket: MDPClusterInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bucket \(bucket.id)")
                .font(.headline)
            Text(bucket.urlPattern)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if !bucket.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions")
                        .font(.subheadline.weight(.semibold))
                    ForEach(bucket.actions.prefix(6)) { action in
                        HStack(alignment: .top, spacing: 8) {
                            Text(action.label)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", action.successRate))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            Button("Open Graph") {
                select(bucket: bucket)
                selectedTab = .graph
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func select(bucket: MDPClusterInfo) {
        selectedClusterId = bucket.id
        if let state = graph.states.first(where: { $0.cluster?.id == bucket.id }) {
            selectedStateId = state.id
        }
    }

    private func similarityScore(for bucket: MDPClusterInfo, query: String) -> Double {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Double(bucket.members) }

        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let haystack = bucketSearchText(bucket)
        let exact = haystack.contains(q) ? 4.0 : 0.0
        let matches = terms.reduce(0.0) { total, term in
            total + (haystack.contains(term) ? 1.0 : 0.0)
        }
        return exact + matches + Double(bucket.members) * 0.05
    }

    private func bucketSearchText(_ bucket: MDPClusterInfo) -> String {
        let actionText = bucket.actions.map { [$0.label, $0.ref, $0.value].joined(separator: " ") }.joined(separator: " ")
        let selectedStateText = graph.states
            .filter { $0.cluster?.id == bucket.id }
            .compactMap { state in
                [state.sampleTitle, state.sampleStateText, state.sampleElementText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            .joined(separator: " ")
        return [bucket.urlPattern, actionText, selectedStateText].joined(separator: " ").lowercased()
    }

    private func scoreLabel(_ score: Double) -> String {
        String(format: "%.1f", score)
    }

    private func bucketTagRow(_ labels: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(3), id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
    }
}
