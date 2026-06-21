//
//  WorkflowGraphView.swift
//  OpenHive — policy graph visualization
//

import SwiftUI

struct WorkflowGraphView: View {
    let workflowId: String
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var loadError: String?

    struct GraphNode: Identifiable {
        let id: String
        let label: String
        let x: CGFloat
        let y: CGFloat
    }

    struct GraphEdge: Identifiable {
        let id: String
        let from: String
        let to: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Policy graph")
                .font(.headline)

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if nodes.isEmpty {
                ProgressView("Loading graph...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    for edge in edges {
                        guard let a = nodes.first(where: { $0.id == edge.from }),
                              let b = nodes.first(where: { $0.id == edge.to })
                        else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: a.x, y: a.y))
                        path.addLine(to: CGPoint(x: b.x, y: b.y))
                        context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                    }
                    for node in nodes {
                        let rect = CGRect(x: node.x - 44, y: node.y - 14, width: 88, height: 28)
                        context.fill(
                            RoundedRectangle(cornerRadius: 8).path(in: rect),
                            with: .color(.accentColor.opacity(0.15))
                        )
                        context.stroke(
                            RoundedRectangle(cornerRadius: 8).path(in: rect),
                            with: .color(.accentColor.opacity(0.35)),
                            lineWidth: 1
                        )
                        context.draw(
                            Text(node.label).font(.system(size: 9, weight: .medium)),
                            at: CGPoint(x: node.x, y: node.y)
                        )
                    }
                }
                .frame(minHeight: 220)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .frame(width: 420, height: 320)
        .onAppear { loadGraph() }
    }

    private func loadGraph() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/workflows/\(workflowId).json")
        guard let data = try? Data(contentsOf: support),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = json["policy"] as? [String: [String: Any]]
        else {
            loadError = "Graph not found for \(workflowId)"
            return
        }

        let ids = Array(policy.keys).sorted()
        var builtNodes: [GraphNode] = []
        var builtEdges: [GraphEdge] = []
        let cols = max(1, Int(ceil(sqrt(Double(ids.count)))))

        for (index, id) in ids.enumerated() {
            let col = index % cols
            let row = index / cols
            let label = (policy[id]?["action"] as? [String: Any])?["type"] as? String
                ?? String(describing: policy[id]?["action"]).prefix(12).description
            builtNodes.append(GraphNode(
                id: id,
                label: String(label.prefix(12)),
                x: 60 + CGFloat(col) * 100,
                y: 40 + CGFloat(row) * 56
            ))
            if let next = policy[id]?["next"] as? String, ids.contains(next) {
                builtEdges.append(GraphEdge(id: "\(id)-\(next)", from: id, to: next))
            }
        }
        nodes = builtNodes
        edges = builtEdges
    }
}
