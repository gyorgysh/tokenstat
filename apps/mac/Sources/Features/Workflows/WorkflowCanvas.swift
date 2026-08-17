// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Content-space size of a node card. Positions in the IR are the top-left.
enum WorkflowNodeMetrics {
    static let width: CGFloat = 200
    static let height: CGFloat = 88
    static let port: CGFloat = 7
}

/// Pan, zoom, nodes, ports and edges. The IR stores `x`/`y`. The runner ignores them.
struct WorkflowCanvas: View {
    @Bindable var model: WorkflowsModel
    var run: WorkflowRunRecord?

    @State private var pan = CGSize.zero
    @State private var panOrigin = CGSize.zero
    @State private var panning = false
    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat = 1
    @State private var magnifying = false
    @State private var linking: PortDrag?
    @State private var dragOrigin: CGPoint?
    @State private var draggingID: String?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.background
                    .contentShape(.rect)
                    .onTapGesture {
                        model.selectNode(nil)
                        model.selectEdge(nil)
                    }
                grid(in: geo.size)
                if let graph = model.working {
                    edges(graph)
                    if let linking {
                        Path { path in
                            path.move(to: linking.start)
                            path.addLine(to: linking.current)
                        }
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .allowsHitTesting(false)
                    }
                    ForEach(graph.nodes) { node in
                        nodeView(node)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width, y: pan.height)
            .gesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in
                let first = canvasSize.width < 1
                canvasSize = size
                if first { fit() }
            }
        }
        .clipped()
        .background(Theme.background)
        .overlay { emptyHint }
        .overlay(alignment: .bottomTrailing) { zoomChrome }
        .onAppear { fitIfNeeded() }
        .onChange(of: model.editorEpoch) { _, _ in fitIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow canvas")
    }

    @ViewBuilder
    private var emptyHint: some View {
        if let graph = model.working, graph.nodes.count <= 1 {
            VStack(spacing: 6) {
                Text("Add a node from the palette")
                    .font(.callout.weight(.medium))
                Text("Or go back and describe a run. A cheap backend drafts the graph. It does not run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: 320)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            .allowsHitTesting(false)
        }
    }

    private var zoomChrome: some View {
        HStack(spacing: 8) {
            Button("Fit", .layout) { fit() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .padding(10)
    }

    private func grid(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            let step: CGFloat = 24
            let z = max(zoom, 0.2)
            let left = floor(((-pan.width / z) - step) / step) * step
            let top = floor(((-pan.height / z) - step) / step) * step
            let right = left + size.width / z + step * 2
            let bottom = top + size.height / z + step * 2
            var x = left
            while x < right {
                var y = top
                while y < bottom {
                    let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.border))
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }

    private func edges(_ graph: WorkflowGraph) -> some View {
        ZStack {
            ForEach(graph.edges) { edge in
                if let from = graph.nodes.first(where: { $0.id == edge.from }),
                   let to = graph.nodes.first(where: { $0.id == edge.to }) {
                    let start = outPort(from)
                    let end = inPort(to)
                    let selected = model.selectedEdgeID == edge.id
                    Path { path in
                        path.move(to: start)
                        let midX = (start.x + end.x) / 2
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: midX, y: start.y),
                            control2: CGPoint(x: midX, y: end.y)
                        )
                    }
                    .stroke(
                        selected ? Theme.accent : edgeTint(edge),
                        style: StrokeStyle(lineWidth: selected ? 2.5 : 1.6, lineCap: .round)
                    )
                    .contentShape(edgeHit(from: start, to: end))
                    .onTapGesture { model.selectEdge(edge.id) }
                }
            }
        }
    }

    private func nodeView(_ node: WorkflowNode) -> some View {
        let selected = model.selectedNodeID == node.id
        let step = run?.steps.first(where: { $0.nodeID == node.id })
        return WorkflowNodeCard(node: node, selected: selected, step: step)
            .overlay(alignment: .leading) {
                port(inPort: true, node: node)
                    .offset(x: -WorkflowNodeMetrics.port)
            }
            .overlay(alignment: .trailing) {
                port(inPort: false, node: node)
                    .offset(x: WorkflowNodeMetrics.port)
            }
            .onTapGesture { model.selectNode(node.id) }
            .highPriorityGesture(nodeDrag(node))
            .position(
                x: node.x + WorkflowNodeMetrics.width / 2,
                y: node.y + WorkflowNodeMetrics.height / 2
            )
    }

    @ViewBuilder
    private func port(inPort: Bool, node: WorkflowNode) -> some View {
        let dot = Circle()
            .fill(Theme.panel)
            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
            .frame(width: WorkflowNodeMetrics.port * 2, height: WorkflowNodeMetrics.port * 2)
            .contentShape(Circle().scale(1.8))
            .accessibilityLabel(inPort ? "Input of \(node.displayTitle)" : "Output of \(node.displayTitle)")
            .help(inPort ? "Input" : "Drag to another node. Option-drag for on error.")
        if inPort {
            dot
        } else {
            dot.highPriorityGesture(linkGesture(from: node))
        }
    }

    private func nodeDrag(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingID != node.id {
                    model.beginNodeMove()
                    model.selectNode(node.id)
                    dragOrigin = CGPoint(x: node.x, y: node.y)
                    draggingID = node.id
                }
                guard let origin = dragOrigin else { return }
                let z = max(zoom, 0.05)
                model.moveNode(
                    id: node.id,
                    x: origin.x + value.translation.width / z,
                    y: origin.y + value.translation.height / z
                )
            }
            .onEnded { _ in
                if let id = draggingID, let node = model.working?.nodes.first(where: { $0.id == id }) {
                    let snap = 8.0
                    model.moveNode(
                        id: id,
                        x: (node.x / snap).rounded() * snap,
                        y: (node.y / snap).rounded() * snap
                    )
                }
                draggingID = nil
                dragOrigin = nil
            }
    }

    private func linkGesture(from node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = outPort(node)
                let z = max(zoom, 0.05)
                let current = CGPoint(
                    x: start.x + value.translation.width / z,
                    y: start.y + value.translation.height / z
                )
                linking = PortDrag(from: node.id, start: start, current: current, when: linkWhen)
            }
            .onEnded { value in
                let start = outPort(node)
                let z = max(zoom, 0.05)
                let current = CGPoint(
                    x: start.x + value.translation.width / z,
                    y: start.y + value.translation.height / z
                )
                if let target = hitInPort(current), target != node.id {
                    model.connect(from: node.id, to: target, when: linking?.when ?? .ok)
                }
                linking = nil
            }
    }

    private var linkWhen: WorkflowEdgeWhen {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option) ? .error : .ok
        #else
        .ok
        #endif
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard linking == nil, draggingID == nil else { return }
                if !panning {
                    panOrigin = pan
                    panning = true
                }
                pan = CGSize(
                    width: panOrigin.width + value.translation.width,
                    height: panOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in
                panning = false
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !magnifying {
                    zoomOrigin = zoom
                    magnifying = true
                }
                zoom = min(2.2, max(0.4, zoomOrigin * value.magnification))
            }
            .onEnded { _ in
                magnifying = false
            }
    }

    private func inPort(_ node: WorkflowNode) -> CGPoint {
        CGPoint(x: node.x, y: node.y + WorkflowNodeMetrics.height / 2)
    }

    private func outPort(_ node: WorkflowNode) -> CGPoint {
        CGPoint(x: node.x + WorkflowNodeMetrics.width, y: node.y + WorkflowNodeMetrics.height / 2)
    }

    private func hitInPort(_ point: CGPoint) -> String? {
        guard let graph = model.working else { return nil }
        return graph.nodes.first { node in
            let port = inPort(node)
            let dx = point.x - port.x
            let dy = point.y - port.y
            return (dx * dx + dy * dy).squareRoot() < 22
        }?.id
    }

    private func edgeTint(_ edge: WorkflowEdge) -> Color {
        if let step = run?.steps.first(where: { $0.nodeID == edge.from }),
           step.status == "ok" || step.status == "error" {
            return Theme.accent.opacity(0.85)
        }
        switch edge.when {
        case .ok: return Theme.border
        case .error: return Theme.danger.opacity(0.7)
        case .always: return Theme.secondary.opacity(0.7)
        }
    }

    private func edgeHit(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let midX = (start.x + end.x) / 2
        path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
        return path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round))
    }

    private func fitIfNeeded() {
        DispatchQueue.main.async { fit() }
    }

    private func fit() {
        guard let graph = model.working, !graph.nodes.isEmpty, canvasSize.width > 1, canvasSize.height > 1 else {
            zoom = 1
            pan = .zero
            return
        }
        let pad: CGFloat = 64
        let minX = CGFloat(graph.nodes.map(\.x).min() ?? 0)
        let minY = CGFloat(graph.nodes.map(\.y).min() ?? 0)
        let maxX = CGFloat(graph.nodes.map { $0.x + Double(WorkflowNodeMetrics.width) }.max() ?? 200)
        let maxY = CGFloat(graph.nodes.map { $0.y + Double(WorkflowNodeMetrics.height) }.max() ?? 88)
        let width = max(maxX - minX, 1) + pad * 2
        let height = max(maxY - minY, 1) + pad * 2
        let z = min(2.2, max(0.4, min(canvasSize.width / width, canvasSize.height / height)))
        zoom = z
        pan = CGSize(
            width: (canvasSize.width - width * z) / 2 - (minX - pad) * z,
            height: (canvasSize.height - height * z) / 2 - (minY - pad) * z
        )
    }
}

private struct PortDrag {
    var from: String
    var start: CGPoint
    var current: CGPoint
    var when: WorkflowEdgeWhen
}

/// Card on the canvas. Mark, title, one-line subtitle, status when a run is live.
struct WorkflowNodeCard: View {
    let node: WorkflowNode
    var selected: Bool
    var step: WorkflowStep?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if node.kind == .agent, let backend = node.backend {
                HarnessMark(id: backend, size: 22)
            } else {
                FeatureMark(name: node.kind.mark, tint: ring, size: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(node.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(node.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let step {
                    StatusPill(status: step.status, text: step.endedLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: WorkflowNodeMetrics.width, height: WorkflowNodeMetrics.height, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(selected ? Theme.accent : ring, lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.10 : 0.05), radius: selected ? 8 : 2, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.kind.label). \(node.displayTitle). \(node.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var ring: Color {
        switch step?.status {
        case "running": return Theme.stateWorking
        case "waiting": return Theme.warning
        case "error": return Theme.danger
        case "ok": return Theme.accent
        default: return Theme.border
        }
    }
}
