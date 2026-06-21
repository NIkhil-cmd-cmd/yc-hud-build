//
//  WorkflowMDPInteractiveView.swift
//  OpenHive — pan/zoom MDP graph with selection and rollout simulation
//

import SwiftUI
import AppKit

struct WorkflowMDPInteractiveView: View {
    let graph: WorkflowMDPGraph
    @Binding var selectedStateId: String?
    @Binding var selectedClusterId: Int?

    @State private var simulationIndex = 0
    @State private var isSimulating = false
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero

    private let nodeSize = CGSize(width: 186, height: 92)

    private var positions: [String: CGPoint] {
        WorkflowMDPParser.layoutPositions(graph: graph, nodeSize: nodeSize)
    }

    private var contentSize: CGSize {
        WorkflowMDPParser.contentSize(positions: positions, nodeSize: nodeSize)
    }

    private var selectedState: MDPStateNode? {
        selectedStateId.flatMap { graph.stateMap[$0] }
    }

    private var activeStateId: String? {
        if isSimulating, simulationIndex < graph.path.count {
            return graph.path[simulationIndex]
        }
        return selectedStateId
    }

    private var activeClusterId: Int? {
        if let selectedState {
            return selectedState.cluster?.id
        }
        return selectedClusterId
    }

    var body: some View {
        HSplitView {
            graphCanvas
                .frame(minWidth: 500)
            inspector
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
        }
        .onAppear {
            if selectedStateId == nil {
                selectedStateId = graph.path.first ?? graph.states.first?.id
            }
            if selectedClusterId == nil {
                selectedClusterId = selectedState.flatMap { $0.cluster?.id }
            }
        }
        .onChange(of: selectedStateId) { _, newValue in
            if let newValue, let state = graph.stateMap[newValue] {
                selectedClusterId = state.cluster?.id
            }
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edgeLayer
                    edgeLabels
                    ForEach(graph.states) { state in
                        if let point = positions[state.id] {
                            stateNode(state)
                                .position(
                                    x: point.x + nodeSize.width / 2,
                                    y: point.y + nodeSize.height / 2
                                )
                        }
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .scaleEffect(canvasScale)
                .offset(canvasOffset)
                .background(Color(nsColor: .controlBackgroundColor))
                .gesture(panGesture)
                .onTapGesture {
                    selectedStateId = nil
                    selectedClusterId = nil
                }
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls.padding(12)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle("Simulate rollout", isOn: $isSimulating)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isSimulating) { _, on in
                    if on {
                        simulationIndex = 0
                        selectedStateId = graph.path.first
                        selectedClusterId = selectedState.flatMap { $0.cluster?.id }
                    }
                }

            if isSimulating, !graph.path.isEmpty {
                Text("Step \(min(simulationIndex + 1, graph.path.count))/\(graph.path.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    simulationIndex = max(0, simulationIndex - 1)
                    syncSelectionToSimulation()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(simulationIndex == 0)

                Button {
                    simulationIndex = min(graph.path.count - 1, simulationIndex + 1)
                    syncSelectionToSimulation()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(simulationIndex >= graph.path.count - 1)

                Button("Reset") {
                    simulationIndex = 0
                    syncSelectionToSimulation()
                }
                .controlSize(.small)
            }

            Spacer()

            Text("\(graph.states.count) states · \(graph.edges.count) transitions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var edgeLayer: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                let start = CGPoint(x: from.x + nodeSize.width, y: from.y + nodeSize.height / 2)
                let end = CGPoint(x: to.x, y: to.y + nodeSize.height / 2)
                var path = Path()
                path.move(to: start)
                let midX = (start.x + end.x) / 2
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: midX, y: start.y),
                    control2: CGPoint(x: midX, y: end.y)
                )
                let highlighted = isHighlighted(edge)
                context.stroke(
                    path,
                    with: .color(highlighted ? .orange : .secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: highlighted ? 3 : 1.5, lineCap: .round)
                )
                drawArrow(context: &context, at: end, from: start, color: highlighted ? .orange : .secondary.opacity(0.55))
            }
        }
    }

    private var edgeLabels: some View {
        ForEach(graph.edges) { edge in
            if let from = positions[edge.from], let to = positions[edge.to] {
                let start = CGPoint(x: from.x + nodeSize.width, y: from.y + nodeSize.height / 2)
                let end = CGPoint(x: to.x, y: to.y + nodeSize.height / 2)
                let midX = (start.x + end.x) / 2
                let midY = (start.y + end.y) / 2
                let label = "\(edge.label)  w:\(String(format: "%.2f", edge.weight))"
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHighlighted(edge) ? .orange : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .position(x: midX, y: midY - 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func stateNode(_ state: MDPStateNode) -> some View {
        let isSelected = activeStateId == state.id
        let isOnPath = graph.path.contains(state.id)
        let clusterSelected = activeClusterId == state.cluster?.id

        return Button {
            selectedStateId = state.id
            selectedClusterId = state.cluster?.id
            if let idx = graph.path.firstIndex(of: state.id) {
                simulationIndex = idx
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("S\(state.id)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    if state.isStart { tag("START", color: .green) }
                    if state.isTerminal { tag("END", color: .orange) }
                    Spacer(minLength: 0)
                }
                Text(state.urlPattern)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                if let title = state.sampleTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if let action = state.primaryAction {
                    Text(action.label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let cluster = state.cluster {
                        tag("B\(cluster.id)", color: clusterSelected ? .accentColor : .blue)
                    }
                    if let artifacts = state.artifacts, artifacts.domHTML != nil {
                        tag("DOM", color: .purple)
                    }
                    if let artifacts = state.artifacts, artifacts.screenshotPath != nil {
                        tag("IMG", color: .pink)
                    }
                }
            }
            .padding(10)
            .frame(width: nodeSize.width, height: nodeSize.height, alignment: .topLeading)
            .background(nodeBackground(isSelected: isSelected, isOnPath: isOnPath, isClusterSelected: clusterSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func nodeBackground(isSelected: Bool, isOnPath: Bool, isClusterSelected: Bool) -> some View {
        if isSelected {
            return Color.accentColor.opacity(0.16).eraseToAnyView()
        } else if isClusterSelected {
            return Color.blue.opacity(0.11).eraseToAnyView()
        } else if isOnPath {
            return Color.orange.opacity(0.08).eraseToAnyView()
        } else {
            return Color.primary.opacity(0.04).eraseToAnyView()
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Node Inspector")
                    .font(.headline)

                if let state = selectedState {
                    inspectorHeader(state)
                    artifactPreview(state)
                    nodeMetadata(state)
                    domPreview(state)
                } else {
                    Text("Click a node to inspect its screenshot, DOM snapshot, and action metadata.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 40)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func inspectorHeader(_ state: MDPStateNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.urlPattern)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
            if let title = state.sampleTitle, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cluster = state.cluster {
                Text("Bucket \(cluster.id) · \(cluster.members) states")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let action = state.primaryAction {
                Text("\(action.label) · support \(action.support) · \(String(format: "%.2f", action.successRate))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func artifactPreview(_ state: MDPStateNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screenshot")
                .font(.subheadline.weight(.semibold))
            if let path = state.artifacts?.screenshotPath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("No screenshot available for this node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func nodeMetadata(_ state: MDPStateNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("State Details")
                .font(.subheadline.weight(.semibold))

            if let element = state.sampleElementText, !element.isEmpty {
                Text("Element")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(element)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let stateText = state.sampleStateText, !stateText.isEmpty {
                Text("State Text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(stateText)
                    .font(.caption.monospaced())
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func domPreview(_ state: MDPStateNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOM")
                .font(.subheadline.weight(.semibold))
            if let dom = state.artifacts?.domHTML, !dom.isEmpty {
                ScrollView {
                    Text(dom)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("No DOM snapshot available for this node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func syncSelectionToSimulation() {
        guard graph.path.indices.contains(simulationIndex) else { return }
        let id = graph.path[simulationIndex]
        selectedStateId = id
        selectedClusterId = graph.stateMap[id]?.cluster?.id
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func isHighlighted(_ edge: MDPEdge) -> Bool {
        if isSimulating, simulationIndex < graph.path.count - 1 {
            return graph.path[simulationIndex] == edge.from && graph.path[simulationIndex + 1] == edge.to
        }
        if let selectedStateId, let selectedClusterId {
            return edge.from == selectedStateId || edge.to == selectedStateId || graph.stateMap[edge.from]?.cluster?.id == selectedClusterId
        }
        if let selectedStateId {
            return edge.from == selectedStateId || edge.to == selectedStateId
        }
        return false
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                canvasOffset = CGSize(
                    width: dragOrigin.width + value.translation.width,
                    height: dragOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragOrigin = canvasOffset
            }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { canvasScale = max(0.5, canvasScale - 0.15) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Text("\(Int(canvasScale * 100))%")
                .font(.caption.monospaced())
                .frame(width: 44)
            Button { canvasScale = min(2.0, canvasScale + 0.15) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button {
                canvasScale = 1.0
                canvasOffset = .zero
                dragOrigin = .zero
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func drawArrow(context: inout GraphicsContext, at end: CGPoint, from start: CGPoint, color: Color) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let arrowLength: CGFloat = 10
        let arrowAngle: CGFloat = .pi / 8
        let p1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )
        var triangle = Path()
        triangle.move(to: end)
        triangle.addLine(to: p1)
        triangle.addLine(to: p2)
        triangle.closeSubpath()
        context.fill(triangle, with: .color(color))
    }
}

private extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}
