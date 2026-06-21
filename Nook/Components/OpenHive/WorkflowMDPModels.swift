//
//  WorkflowMDPModels.swift
//  OpenHive — parse workflow JSON into MDP states, edges, and clusters
//

import Foundation
import CoreGraphics

struct MDPNodeArtifacts: Equatable {
    let domHTML: String?
    let screenshotPath: String?
    let accessibilityPath: String?
    let viewportScreenshotPath: String?
    let fullPageScreenshotPath: String?
    let elementScreenshotPath: String?
}

struct MDPActionCandidate: Identifiable, Equatable {
    let id: String
    let type: String
    let ref: String
    let value: String
    let successRate: Double
    let support: Int

    var label: String {
        switch type {
        case "navigate":
            return value.isEmpty ? "Navigate" : "Go to \(value)"
        case "click":
            return value.isEmpty ? "Click" : "Click “\(WorkflowMDPParser.truncate(value, 48))”"
        case "type", "fill":
            return value.isEmpty ? "Type" : "Type “\(WorkflowMDPParser.truncate(value, 48))”"
        default:
            return type.capitalized
        }
    }
}

struct MDPStateNode: Identifiable, Equatable {
    let id: String
    let urlPattern: String
    let sampleURL: String?
    let sampleTitle: String?
    let sampleStateText: String?
    let sampleElementText: String?
    let sampleAction: MDPActionCandidate?
    let isStart: Bool
    let isTerminal: Bool
    let cluster: MDPClusterInfo?
    let primaryAction: MDPActionCandidate?
    let nextStateId: String?
    let artifacts: MDPNodeArtifacts?
}

struct MDPClusterInfo: Equatable {
    let id: Int
    let urlPattern: String
    let members: Int
    let actions: [MDPActionCandidate]
}

struct MDPEdge: Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let label: String
    let actionType: String
    let weight: Double
    let support: Int
}

struct WorkflowMDPGraph: Equatable {
    let workflowId: String
    let workflowName: String
    let states: [MDPStateNode]
    let edges: [MDPEdge]
    let path: [String]
    let buckets: [MDPClusterInfo]

    var stateMap: [String: MDPStateNode] {
        Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
    }
}

enum WorkflowMDPLoadError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum WorkflowMDPParser {
    static func load(workflowId: String) -> Result<WorkflowMDPGraph, WorkflowMDPLoadError> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/workflows/\(workflowId).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.message("Could not load workflow “\(workflowId)”"))
        }
        return parse(json: json, workflowId: workflowId)
    }

    static func parse(json: [String: Any], workflowId: String) -> Result<WorkflowMDPGraph, WorkflowMDPLoadError> {
        let name = json["name"] as? String ?? workflowId
        let policy = json["policy"] as? [String: [String: Any]] ?? [:]
        let rawNodes = json["nodes"] as? [String: [String: Any]] ?? [:]
        let policyNodesRaw = json["policyNodes"] as? [[String: Any]] ?? []

        guard !policy.isEmpty else {
            return .failure(.message("No MDP policy graph — save a workflow after recording steps."))
        }

        let clusters = buildClusters(policyNodesRaw)
        let startId = policyStartId(policy)
        let path = orderedPath(from: startId, policy: policy)

        var states: [MDPStateNode] = []
        var edges: [MDPEdge] = []

        for (id, entry) in policy {
            let meta = rawNodes[id]
            let sampleStep = (meta?["sample_step"] as? [String: Any])
                ?? (meta?["sampleStep"] as? [String: Any])
            let urlPattern = (meta?["url_pattern"] as? String)
                ?? Int(id).flatMap { clusters[$0]?.urlPattern }
                ?? "state \(id)"
            let sampleURL = meta?["url"] as? String
                ?? sampleStep?["url"] as? String
            let sampleTitle = meta?["sampleTitle"] as? String
                ?? meta?["title"] as? String
                ?? sampleStep?["title"] as? String
            let sampleStateText = meta?["sampleStateText"] as? String
                ?? meta?["stateText"] as? String
                ?? sampleStep?["stateText"] as? String
            let sampleElementText = meta?["sampleElementText"] as? String
                ?? (meta?["sampleSelectedElement"] as? [String: Any]).flatMap { $0["text"] as? String }
                ?? (sampleStep?["selectedElement"] as? [String: Any]).flatMap { $0["text"] as? String }
                ?? (sampleStep?["action"] as? [String: Any]).flatMap { $0["text"] as? String }
                ?? (sampleStep?["action"] as? [String: Any]).flatMap { $0["name"] as? String }
            let nextRaw = entry["next"]
            let nextId: String? = {
                if let n = nextRaw as? Int { return String(n) }
                if let n = nextRaw as? String, !n.isEmpty { return n }
                return nil
            }()
            let hasNext = nextId.flatMap { policy[$0] != nil } ?? false
            let cluster = Int(id).flatMap { clusters[$0] }
            let actionDict = entry["action"] as? [String: Any] ?? [:]
            let primary = actionCandidate(from: actionDict, id: "\(id)-primary")
            let artifacts = nodeArtifacts(from: meta, sampleStep: sampleStep)

            states.append(
                MDPStateNode(
                    id: id,
                    urlPattern: urlPattern,
                    sampleURL: sampleURL,
                    sampleTitle: sampleTitle,
                    sampleStateText: sampleStateText,
                    sampleElementText: sampleElementText,
                    sampleAction: primary,
                    isStart: id == startId,
                    isTerminal: !hasNext,
                    cluster: cluster,
                    primaryAction: primary,
                    nextStateId: hasNext ? nextId : nil,
                    artifacts: artifacts
                )
            )

            if let nextId, hasNext, let primary {
                edges.append(
                    MDPEdge(
                        id: "\(id)->\(nextId)",
                        from: id,
                        to: nextId,
                        label: primary.label,
                        actionType: primary.type,
                        weight: primary.successRate,
                        support: primary.support
                    )
                )
            }
        }

        states.sort { lhs, rhs in
            let li = Int(lhs.id) ?? Int.max
            let ri = Int(rhs.id) ?? Int.max
            if li != ri { return li < ri }
            return lhs.id < rhs.id
        }

        return .success(
            WorkflowMDPGraph(
                workflowId: workflowId,
                workflowName: name,
                states: states,
                edges: edges,
                path: path,
                buckets: clusters.values.sorted { lhs, rhs in
                    if lhs.members != rhs.members { return lhs.members > rhs.members }
                    return lhs.id < rhs.id
                }
            )
        )
    }

    static func layoutPositions(
        graph: WorkflowMDPGraph,
        nodeSize: CGSize = CGSize(width: 168, height: 76),
        hGap: CGFloat = 96,
        vGap: CGFloat = 48
    ) -> [String: CGPoint] {
        let layers = layerIndices(graph: graph)
        var byLayer: [Int: [String]] = [:]
        for (id, layer) in layers {
            byLayer[layer, default: []].append(id)
        }
        for key in byLayer.keys {
            byLayer[key]?.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }

        var positions: [String: CGPoint] = [:]
        let maxLayer = byLayer.keys.max() ?? 0
        for layer in 0...maxLayer {
            guard let ids = byLayer[layer] else { continue }
            let count = CGFloat(ids.count)
            for (index, id) in ids.enumerated() {
                let x = CGFloat(layer) * (nodeSize.width + hGap) + 40
                let y = (CGFloat(index) - (count - 1) / 2) * (nodeSize.height + vGap) + 120
                positions[id] = CGPoint(x: x, y: y)
            }
        }
        return positions
    }

    static func contentSize(positions: [String: CGPoint], nodeSize: CGSize) -> CGSize {
        guard !positions.isEmpty else { return CGSize(width: 800, height: 500) }
        let maxX = positions.values.map(\.x).max() ?? 0
        let maxY = positions.values.map(\.y).max() ?? 0
        let minY = positions.values.map(\.y).min() ?? 0
        return CGSize(width: maxX + nodeSize.width + 80, height: maxY - minY + nodeSize.height + 120)
    }

    static func truncate(_ value: String, _ max: Int) -> String {
        if value.count <= max { return value }
        return String(value.prefix(max - 1)) + "…"
    }

    // MARK: - Private

    private static func policyStartId(_ policy: [String: [String: Any]]) -> String {
        if let numeric = policy.keys.compactMap({ Int($0) }).sorted().first {
            return String(numeric)
        }
        return policy.keys.sorted().first ?? "0"
    }

    private static func orderedPath(from start: String, policy: [String: [String: Any]]) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        var current: String? = start
        while let id = current, !seen.contains(id), policy[id] != nil {
            seen.insert(id)
            ids.append(id)
            let nextRaw = policy[id]?["next"]
            let next: String? = {
                if let n = nextRaw as? Int { return String(n) }
                if let n = nextRaw as? String, !n.isEmpty { return n }
                return nil
            }()
            current = next.flatMap { policy[$0] != nil ? $0 : nil }
        }
        return ids
    }

    private static func layerIndices(graph: WorkflowMDPGraph) -> [String: Int] {
        var layers: [String: Int] = [:]
        guard let start = graph.path.first else {
            for (i, s) in graph.states.enumerated() { layers[s.id] = i }
            return layers
        }
        var queue: [(String, Int)] = [(start, 0)]
        var seen = Set<String>()
        while !queue.isEmpty {
            let (id, layer) = queue.removeFirst()
            if seen.contains(id) { continue }
            seen.insert(id)
            layers[id] = max(layers[id] ?? 0, layer)
            if let next = graph.stateMap[id]?.nextStateId {
                queue.append((next, layer + 1))
            }
        }
        for state in graph.states where layers[state.id] == nil {
            layers[state.id] = 0
        }
        return layers
    }

    private static func buildClusters(_ raw: [[String: Any]]) -> [Int: MDPClusterInfo] {
        var out: [Int: MDPClusterInfo] = [:]
        for entry in raw {
            guard let id = entry["id"] as? Int else { continue }
            let pattern = entry["urlPattern"] as? String ?? ""
            let members = entry["members"] as? Int ?? 0
            let actionsRaw = entry["actions"] as? [[String: Any]] ?? []
            let actions = actionsRaw.enumerated().compactMap { index, action -> MDPActionCandidate? in
                actionCandidate(from: action, id: "\(id)-\(index)")
            }
            out[id] = MDPClusterInfo(id: id, urlPattern: pattern, members: members, actions: actions)
        }
        return out
    }

    private static func nodeArtifacts(from meta: [String: Any]?, sampleStep: [String: Any]?) -> MDPNodeArtifacts? {
        guard let meta else { return nil }
        let artifactDict = meta["artifacts"] as? [String: Any]
        let sampleArtifacts = sampleStep?["artifacts"] as? [String: Any]
        let domHTML = meta["domHTML"] as? String
            ?? meta["domHtml"] as? String
            ?? sampleStep?["domHTML"] as? String
            ?? sampleStep?["domHtml"] as? String
            ?? sampleArtifacts?["dom"] as? String
        let screenshotPath = meta["snapshotPath"] as? String
            ?? meta["screenshotPath"] as? String
            ?? sampleStep?["snapshotPath"] as? String
            ?? sampleStep?["screenshotPath"] as? String
            ?? artifactDict?["screenshotPath"] as? String
            ?? sampleArtifacts?["screenshotPath"] as? String
            ?? sampleArtifacts?["viewportScreenshot"] as? String
            ?? sampleArtifacts?["fullPageScreenshot"] as? String
            ?? sampleArtifacts?["elementScreenshot"] as? String
        let accessibilityPath = meta["accessibilityPath"] as? String
            ?? artifactDict?["accessibility"] as? String
            ?? sampleStep?["accessibilityPath"] as? String
            ?? sampleArtifacts?["accessibility"] as? String
        let viewportScreenshotPath = meta["viewportScreenshotPath"] as? String
            ?? artifactDict?["viewportScreenshot"] as? String
            ?? sampleStep?["viewportScreenshotPath"] as? String
            ?? sampleArtifacts?["viewportScreenshot"] as? String
        let fullPageScreenshotPath = meta["fullPageScreenshotPath"] as? String
            ?? artifactDict?["fullPageScreenshot"] as? String
            ?? sampleStep?["fullPageScreenshotPath"] as? String
            ?? sampleArtifacts?["fullPageScreenshot"] as? String
        let elementScreenshotPath = meta["elementScreenshotPath"] as? String
            ?? artifactDict?["elementScreenshot"] as? String
            ?? sampleStep?["elementScreenshotPath"] as? String
            ?? sampleArtifacts?["elementScreenshot"] as? String
        if domHTML == nil,
           screenshotPath == nil,
           accessibilityPath == nil,
           viewportScreenshotPath == nil,
           fullPageScreenshotPath == nil,
           elementScreenshotPath == nil {
            return nil
        }
        return MDPNodeArtifacts(
            domHTML: domHTML,
            screenshotPath: screenshotPath,
            accessibilityPath: accessibilityPath,
            viewportScreenshotPath: viewportScreenshotPath,
            fullPageScreenshotPath: fullPageScreenshotPath,
            elementScreenshotPath: elementScreenshotPath
        )
    }

    private static func actionCandidate(from action: [String: Any], id: String) -> MDPActionCandidate? {
        let type = (action["type"] as? String ?? "step").lowercased()
        let ref = action["ref"] as? String ?? action["selector"] as? String ?? ""
        let value: String = {
            if type == "navigate" { return action["url"] as? String ?? "" }
            return action["value"] as? String ?? action["text"] as? String ?? ""
        }()
        let success = (action["successRate"] as? NSNumber)?.doubleValue
            ?? (action["success"] as? NSNumber)?.doubleValue
            ?? 1.0
        let support = action["support"] as? Int ?? 1
        return MDPActionCandidate(
            id: id,
            type: type,
            ref: ref,
            value: value,
            successRate: success,
            support: support
        )
    }
}
