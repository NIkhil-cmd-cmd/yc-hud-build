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
    let isPrimary: Bool
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
    private static var openHiveSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive", isDirectory: true)
    }

    static func load(workflowId: String) -> Result<WorkflowMDPGraph, WorkflowMDPLoadError> {
        for url in workflowJSONURLs(workflowId: workflowId) {
            if let result = load(from: url, workflowId: workflowId) {
                return result
            }
        }
        return .failure(.message("Could not load workflow “\(workflowId)”"))
    }

    private static func workflowJSONURLs(workflowId: String) -> [URL] {
        let root = openHiveSupportRoot
        return [
            root.appendingPathComponent("workflows/\(workflowId).json"),
            root.appendingPathComponent("mdps/\(workflowId).json"),
        ]
    }

    private static func load(from url: URL, workflowId: String) -> Result<WorkflowMDPGraph, WorkflowMDPLoadError>? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch parse(json: json, workflowId: workflowId) {
        case .success(let graph):
            return .success(graph)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func loadJSON(workflowId: String) -> [String: Any]? {
        for url in workflowJSONURLs(workflowId: workflowId) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return json
        }
        return nil
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
        let transitionsRaw = json["transitions"] as? [[String: Any]] ?? []

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
            let hasNext = nextId.flatMap { policy[$0] != nil || rawNodes[$0] != nil } ?? false
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
                    isTerminal: !hasNext && !transitionsRaw.contains { ($0["from"] as? String) == id || ($0["from"] as? Int).map(String.init) == id },
                    cluster: cluster,
                    primaryAction: primary,
                    nextStateId: hasNext ? nextId : nil,
                    artifacts: artifacts
                )
            )
        }

        if !transitionsRaw.isEmpty {
            edges = parseTransitions(transitionsRaw, policy: policy, clusters: clusters, rawNodes: rawNodes)
            states = mergeTransitionStates(
                existing: states,
                transitions: transitionsRaw,
                policy: policy,
                clusters: clusters,
                rawNodes: rawNodes,
                startId: startId
            )
        } else {
            for (id, entry) in policy {
                let nextRaw = entry["next"]
                let nextId: String? = {
                    if let n = nextRaw as? Int { return String(n) }
                    if let n = nextRaw as? String, !n.isEmpty { return n }
                    return nil
                }()
                guard let nextId, policy[nextId] != nil else { continue }
                let actionDict = entry["action"] as? [String: Any] ?? [:]
                guard let primary = actionCandidate(from: actionDict, id: "\(id)-primary") else { continue }
                edges.append(
                    MDPEdge(
                        id: "\(id)->\(nextId)",
                        from: id,
                        to: nextId,
                        label: primary.label,
                        actionType: primary.type,
                        weight: primary.successRate,
                        support: primary.support,
                        isPrimary: true
                    )
                )
            }
            edges.append(contentsOf: alternateEdges(from: clusters, policy: policy, primaryEdges: edges))
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
        var adjacency: [String: [String]] = [:]
        for edge in graph.edges {
            adjacency[edge.from, default: []].append(edge.to)
        }

        guard let start = graph.path.first ?? graph.states.first?.id else {
            for (i, s) in graph.states.enumerated() { layers[s.id] = i }
            return layers
        }

        var queue: [(String, Int)] = [(start, 0)]
        var seen = Set<String>()
        while !queue.isEmpty {
            let (id, layer) = queue.removeFirst()
            if seen.contains(id) {
                layers[id] = min(layers[id] ?? layer, layer)
                continue
            }
            seen.insert(id)
            layers[id] = layer
            for next in adjacency[id] ?? [] {
                queue.append((next, layer + 1))
            }
        }

        for state in graph.states where layers[state.id] == nil {
            layers[state.id] = 0
        }
        return layers
    }

    private static func stringId(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? Int { return String(n) }
        return nil
    }

    private static func parseTransitions(
        _ raw: [[String: Any]],
        policy: [String: [String: Any]],
        clusters: [Int: MDPClusterInfo],
        rawNodes: [String: [String: Any]]
    ) -> [MDPEdge] {
        raw.compactMap { entry -> MDPEdge? in
            guard let from = stringId(entry["from"]),
                  let to = stringId(entry["to"]) else { return nil }
            let actionDict = entry["action"] as? [String: Any] ?? [:]
            let candidate = actionCandidate(from: actionDict, id: "\(from)->\(to)")
            let weight = (entry["weight"] as? NSNumber)?.doubleValue ?? candidate?.successRate ?? 1.0
            let support = entry["support"] as? Int ?? candidate?.support ?? 1
            let isPrimary = entry["primary"] as? Bool ?? {
                guard let nextRaw = policy[from]?["next"] else { return false }
                return stringId(nextRaw) == to
            }()
            return MDPEdge(
                id: "\(from)->\(to)-\(candidate?.id ?? "edge")",
                from: from,
                to: to,
                label: candidate?.label ?? "Transition",
                actionType: candidate?.type ?? "step",
                weight: weight,
                support: support,
                isPrimary: isPrimary
            )
        }
    }

    private static func mergeTransitionStates(
        existing: [MDPStateNode],
        transitions: [[String: Any]],
        policy: [String: [String: Any]],
        clusters: [Int: MDPClusterInfo],
        rawNodes: [String: [String: Any]],
        startId: String
    ) -> [MDPStateNode] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let referenced = Set(transitions.flatMap { t -> [String] in
            [stringId(t["from"]), stringId(t["to"])].compactMap { $0 }
        })

        for id in referenced where byId[id] == nil {
            let meta = rawNodes[id]
            let cluster = Int(id).flatMap { clusters[$0] }
            let urlPattern = (meta?["url_pattern"] as? String)
                ?? cluster?.urlPattern
                ?? "state \(id)"
            byId[id] = MDPStateNode(
                id: id,
                urlPattern: urlPattern,
                sampleURL: meta?["url"] as? String,
                sampleTitle: meta?["title"] as? String,
                sampleStateText: meta?["stateText"] as? String,
                sampleElementText: nil,
                sampleAction: nil,
                isStart: id == startId,
                isTerminal: policy[id] == nil,
                cluster: cluster,
                primaryAction: nil,
                nextStateId: stringId(policy[id]?["next"]),
                artifacts: nodeArtifacts(from: meta, sampleStep: nil)
            )
        }

        return byId.values.sorted { lhs, rhs in
            let li = Int(lhs.id) ?? Int.max
            let ri = Int(rhs.id) ?? Int.max
            if li != ri { return li < ri }
            return lhs.id < rhs.id
        }
    }

    /// Build stale/alternate edges from cluster action candidates when explicit transitions are absent.
    private static func alternateEdges(
        from clusters: [Int: MDPClusterInfo],
        policy: [String: [String: Any]],
        primaryEdges: [MDPEdge]
    ) -> [MDPEdge] {
        var edges: [MDPEdge] = []
        let primaryKeys = Set(primaryEdges.map { "\($0.from)->\($0.label)" })

        for (stateId, entry) in policy {
            guard let clusterId = Int(stateId),
                  let cluster = clusters[clusterId],
                  cluster.actions.count > 1 else { continue }
            let primaryLabel = actionCandidate(
                from: entry["action"] as? [String: Any] ?? [:],
                id: "\(stateId)-primary"
            )?.label

            for (index, action) in cluster.actions.enumerated() {
                if action.label == primaryLabel { continue }
                let key = "\(stateId)->\(action.label)"
                if primaryKeys.contains(key) { continue }
                // Link alternate actions to the next policy hop as a weak stale edge for visualization.
                guard let nextRaw = entry["next"],
                      let nextId = stringId(nextRaw),
                      policy[nextId] != nil else { continue }
                edges.append(
                    MDPEdge(
                        id: "\(stateId)->\(nextId)-alt-\(index)",
                        from: stateId,
                        to: nextId,
                        label: action.label,
                        actionType: action.type,
                        weight: action.successRate,
                        support: action.support,
                        isPrimary: false
                    )
                )
            }
        }
        return edges
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

        let domHTML = firstString(
            meta["domHTML"], meta["domHtml"],
            sampleStep?["domHTML"], sampleStep?["domHtml"],
            sampleArtifacts?["dom"]
        )
        let screenshotPath = firstString(
            meta["snapshotPath"], meta["screenshotPath"],
            sampleStep?["snapshotPath"], sampleStep?["screenshotPath"],
            artifactDict?["screenshotPath"], sampleArtifacts?["screenshotPath"],
            sampleArtifacts?["viewportScreenshot"], sampleArtifacts?["fullPageScreenshot"],
            sampleArtifacts?["elementScreenshot"]
        )
        let accessibilityPath = firstString(
            meta["accessibilityPath"], artifactDict?["accessibility"],
            sampleStep?["accessibilityPath"], sampleArtifacts?["accessibility"]
        )
        let viewportScreenshotPath = firstString(
            meta["viewportScreenshotPath"], artifactDict?["viewportScreenshot"],
            sampleStep?["viewportScreenshotPath"], sampleArtifacts?["viewportScreenshot"]
        )
        let fullPageScreenshotPath = firstString(
            meta["fullPageScreenshotPath"], artifactDict?["fullPageScreenshot"],
            sampleStep?["fullPageScreenshotPath"], sampleArtifacts?["fullPageScreenshot"]
        )
        let elementScreenshotPath = firstString(
            meta["elementScreenshotPath"], artifactDict?["elementScreenshot"],
            sampleStep?["elementScreenshotPath"], sampleArtifacts?["elementScreenshot"]
        )

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

    private static func firstString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return nil
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
