//
//  WorkflowMDPInteractiveView.swift
//  OpenHive — pan/zoom MDP graph with selection and rollout simulation
//

import SwiftUI

struct WorkflowMDPInteractiveView: View {
    let graph: WorkflowMDPGraph

    @State private var selectedStateId: String?
    @State private var simulationIndex = 0
    @State private var isSimulating = false
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero

    private let nodeSize = CGSize(width: 168, height: 76)

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

    var body: some View {
        HSplitView {
            graphCanvas
                .frame(minWidth: 420)
            inspector
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        }
        .onAppear {
            selectedStateId = graph.path.first
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        VStack(spacing: 0) {
            simulationBar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edgeLayer
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
                .onTapGesture { selectedStateId = nil }
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls.padding(12)
            }
        }
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
                let highlighted = isSimulating
                    && simulationIndex < graph.path.count - 1
                    && graph.path[simulationIndex] == edge.from
                    && graph.path[simulationIndex + 1] == edge.to
                context.stroke(
                    path,
                    with: .color(highlighted ? .orange : .secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: highlighted ? 2.5 : 1.5, lineCap: .round)
                )
                drawArrow(context: &context, at: end, from: start, color: highlighted ? .orange : .secondary.opacity(0.55))
            }
        }
    }

    private func stateNode(_ state: MDPStateNode) -> some View {
        let isSelected = activeStateId == state.id
        let isOnPath = graph.path.contains(state.id)

        return Button {
            selectedStateId = state.id
            if isSimulating, let idx = graph.path.firstIndex(of: state.id) {
                simulationIndex = idx
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
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
                if let action = state.primaryAction {
                    Text(action.label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(width: nodeSize.width, height: nodeSize.height, alignment: .topLeading)
            .background(nodeBackground(isSelected: isSelected, isOnPath: isOnPath))
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

    @ViewBuilder
    private func nodeBackground(isSelected: Bool, isOnPath: Bool) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.14)
        } else if isOnPath {
            Color.blue.opacity(0.07)
        } else {
            Color.primary.opacity(0.04)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
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

    // MARK: - Simulation

    private var simulationBar: some View {
        HStack(spacing: 10) {
            Toggle("Simulate rollout", isOn: $isSimulating)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isSimulating) { _, on in
                    if on {
                        simulationIndex = 0
                        selectedStateId = graph.path.first
                    }
                }

            if isSimulating {
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
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let state = selectedState ?? graph.states.first {
                    inspectorSection("State S\(state.id)") {
                        labeledRow("URL pattern", state.urlPattern)
                        if let url = state.sampleURL, !url.isEmpty {
                            labeledRow("Sample URL", url)
                        }
                        if let next = state.nextStateId {
                            labeledRow("Policy next", "S\(next)")
                        } else {
                            labeledRow("Policy next", "Terminal")
                        }
                    }

                    if let action = state.primaryAction {
                        inspectorSection("Primary action (π)") {
                            actionDetail(action)
                        }
                    }

                    if let cluster = state.cluster, !cluster.actions.isEmpty {
                        inspectorSection("Action candidates (\(cluster.members) visits)") {
                            ForEach(cluster.actions) { candidate in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(candidate.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    successBar(candidate.successRate, support: candidate.support)
                                    if !candidate.ref.isEmpty {
                                        Text(candidate.ref)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                } else {
                    Text("Select a state node to inspect its policy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                inspectorSection("MDP legend") {
                    legendRow(color: .green, text: "START — initial state s₀")
                    legendRow(color: .orange, text: "END — terminal state")
                    legendRow(color: .accentColor, text: "Selected / simulation cursor")
                    legendRow(color: .blue.opacity(0.5), text: "States on optimal policy path")
                    legendRow(color: .orange, text: "Highlighted edge during simulation")
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionDetail(_ action: MDPActionCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.label)
                .font(.system(size: 13, weight: .semibold))
            successBar(action.successRate, support: action.support)
            Text("type: \(action.type)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func successBar(_ rate: Double, support: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%.0f%% success", rate * 100))
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("n=\(support)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(rate >= 0.8 ? Color.green : (rate >= 0.5 ? Color.orange : Color.red))
                        .frame(width: geo.size.width * CGFloat(min(max(rate, 0), 1)))
                }
            }
            .frame(height: 6)
        }
    }

    private func legendRow(color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func drawArrow(context: inout GraphicsContext, at tip: CGPoint, from start: CGPoint, color: Color) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let len: CGFloat = 8
        let left = CGPoint(
            x: tip.x - len * cos(angle - .pi / 6),
            y: tip.y - len * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: tip.x - len * cos(angle + .pi / 6),
            y: tip.y - len * sin(angle + .pi / 6)
        )
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: left)
        arrow.move(to: tip)
        arrow.addLine(to: right)
        context.stroke(arrow, with: .color(color), lineWidth: 1.5)
    }

    private func syncSelectionToSimulation() {
        if simulationIndex < graph.path.count {
            selectedStateId = graph.path[simulationIndex]
        }
    }
}
