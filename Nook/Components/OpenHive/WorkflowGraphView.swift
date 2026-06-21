//
//  WorkflowGraphView.swift
//  OpenHive — workflow step timeline + policy graph
//

import SwiftUI

struct WorkflowGraphView: View {
    let workflowId: String

    @State private var workflowName = ""
    @State private var steps: [WorkflowStep] = []
    @State private var policyNodes: [PolicyNode] = []
    @State private var loadError: String?

    struct WorkflowStep: Identifiable {
        let id: Int
        let type: String
        let title: String
        let subtitle: String
        let icon: String
        let tint: Color
    }

    struct PolicyNode: Identifiable {
        let id: String
        let label: String
        let next: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        errorCard(loadError)
                    } else if steps.isEmpty && policyNodes.isEmpty {
                        ProgressView("Loading workflow…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        if !steps.isEmpty {
                            stepsSection
                        }
                        if !policyNodes.isEmpty {
                            policySection
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, minHeight: 520)
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
                Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded steps")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
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
                                .fixedSize(horizontal: false, vertical: true)
                            if !step.subtitle.isEmpty {
                                Text(step.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .padding(.bottom, index < steps.count - 1 ? 4 : 0)
                }
            }
        }
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Policy graph")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(policyNodes.enumerated()), id: \.element.id) { index, node in
                        HStack(spacing: 10) {
                            policyChip(node)
                            if index < policyNodes.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func policyChip(_ node: PolicyNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Node \(node.id)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(node.label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: 120, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
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
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/workflows/\(workflowId).json")
        guard let data = try? Data(contentsOf: support),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            loadError = "Could not load workflow file for “\(workflowId)”."
            return
        }

        workflowName = json["name"] as? String ?? workflowId
        let rawActions = (json["actions"] as? [[String: Any]]) ?? actionsFromPolicy(json)
        steps = rawActions.enumerated().map { index, action in
            makeStep(index: index, action: action)
        }

        if let policy = json["policy"] as? [String: [String: Any]] {
            let ids = orderedPolicyIds(policy)
            policyNodes = ids.compactMap { id in
                guard let entry = policy[id] else { return nil }
                let action = entry["action"] as? [String: Any] ?? [:]
                let label = stepLabel(for: action)
                let next = entry["next"] as? String
                return PolicyNode(id: id, label: label, next: next)
            }
        }

        if steps.isEmpty && policyNodes.isEmpty {
            loadError = "This workflow has no recorded steps yet. Record and save it again."
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
            let next = entry["next"] as? String ?? ""
            current = policy[next] != nil ? next : nil
        }
        return actions
    }

    private func orderedPolicyIds(_ policy: [String: [String: Any]]) -> [String] {
        let start: String
        if let numericStart = policy.keys.compactMap({ Int($0) }).sorted().first {
            start = String(numericStart)
        } else {
            start = policy.keys.sorted().first ?? ""
        }
        guard !start.isEmpty else { return Array(policy.keys).sorted() }

        var ids: [String] = []
        var seen = Set<String>()
        var current: String? = start
        while let id = current, !seen.contains(id), policy[id] != nil {
            seen.insert(id)
            ids.append(id)
            let next = policy[id]?["next"] as? String ?? ""
            current = policy[next] != nil ? next : nil
        }
        for id in policy.keys.sorted() where !seen.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private func makeStep(index: Int, action: [String: Any]) -> WorkflowStep {
        let type = (action["type"] as? String ?? "unknown").lowercased()
        let title = stepLabel(for: action)
        let subtitle = stepSubtitle(for: action)
        return WorkflowStep(
            id: index,
            type: type,
            title: title,
            subtitle: subtitle,
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
            if !text.isEmpty {
                return "Click “\(truncate(text, 72))”"
            }
            let selector = cleaned(action["selector"] as? String)
            if !selector.isEmpty {
                return "Click \(truncate(selector, 72))"
            }
            let name = cleaned(action["name"] as? String)
            if !name.isEmpty {
                return "Click \(name)"
            }
            return "Click element"
        case "type", "fill":
            let value = cleaned(action["value"] as? String ?? action["text"] as? String)
            if !value.isEmpty {
                return "Type “\(truncate(value, 72))”"
            }
            return "Type into field"
        default:
            return type
        }
    }

    private func stepSubtitle(for action: [String: Any]) -> String {
        switch action["type"] as? String {
        case "navigate":
            return action["url"] as? String ?? ""
        case "click":
            var parts: [String] = []
            let selector = cleaned(action["selector"] as? String)
            if !selector.isEmpty { parts.append(selector) }
            let name = cleaned(action["name"] as? String)
            if !name.isEmpty { parts.append("name: \(name)") }
            return parts.joined(separator: " · ")
        case "type", "fill":
            var parts: [String] = []
            let selector = cleaned(action["selector"] as? String)
            if !selector.isEmpty { parts.append(selector) }
            let name = cleaned(action["name"] as? String)
            if !name.isEmpty { parts.append("name: \(name)") }
            return parts.joined(separator: " · ")
        default:
            return ""
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
        value?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func truncate(_ value: String, _ max: Int) -> String {
        if value.count <= max { return value }
        return String(value.prefix(max - 1)) + "…"
    }
}
