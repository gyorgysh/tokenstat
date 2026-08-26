// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

#if os(macOS)
import SwiftUI
import AppKit

/// Content-space size of a node card. Positions in the IR are the top-left.
enum WorkflowNodeMetrics {
    static let width: CGFloat = 228
    static let height: CGFloat = 120
    static let port: CGFloat = 7
    static let rowGap: CGFloat = 160
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
    @State private var armed: ArmedLink?
    @State private var dragOrigin: CGPoint?
    @State private var draggingID: String?
    @State private var addingAfter: String?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.background
                    .contentShape(.rect)
                    .gesture(panGesture)
                    .onTapGesture {
                        model.selectNode(nil)
                        model.selectEdge(nil)
                        armed = nil
                    }
                grid(in: geo.size)
                if let graph = model.working {
                    edges(graph)
                    if let linking {
                        Path { path in
                            path.move(to: linking.start)
                            path.addLine(to: linking.current)
                        }
                        .stroke(portTint(linking.when), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .allowsHitTesting(false)
                    }
                    ForEach(graph.nodes) { node in
                        nodeView(node)
                        if showsAdd(for: node, in: graph) {
                            addButton(for: node)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width, y: pan.height)
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
        .overlay(alignment: .topLeading) { emptyHint }
        .overlay(alignment: .bottomTrailing) { zoomChrome }
        .onAppear { fitIfNeeded() }
        .onChange(of: model.editorEpoch) { _, _ in fitIfNeeded() }
        .focusable()
        // The canvas is focusable so Escape and Delete reach it, and AppKit
        // repays that by drawing a system focus ring around the whole pane the
        // moment a node is clicked: a blue rectangle down every edge of the
        // editor, in the system accent rather than any colour this app uses.
        // The selected node already shows what is selected.
        .focusEffectDisabled()
        .onExitCommand { armed = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow canvas")
    }

    @ViewBuilder
    private var emptyHint: some View {
        if let graph = model.working, graph.nodes.count <= 1 || graph.edges.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("The run goes top to bottom")
                    .font(Theme.callout.weight(.medium))
                Text("The top card is the starting prompt. Press + under a card to add the next step. Green is on success. Red is on error.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !exampleRecipes.isEmpty {
                    Text("Or drop in an example")
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    WorkflowRecipeChips(recipes: exampleRecipes) { recipe in
                        model.applyRecipe(recipe)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            .padding(16)
        }
    }

    private var exampleRecipes: [WorkflowRecipe] {
        WorkflowRecipes.recipes(from: model.pickerBackends())
    }

    private var zoomChrome: some View {
        HStack(spacing: 8) {
            Button("Fit", .layout) { fit() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Text("\(Int((zoom * 100).rounded()))%")
                .font(Theme.caption.monospacedDigit())
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
                    let start = outPort(from, when: edge.when)
                    let end = inPort(to)
                    let selected = model.selectedEdgeID == edge.id
                    Path { path in
                        path.move(to: start)
                        let midY = (start.y + end.y) / 2
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: start.x, y: midY),
                            control2: CGPoint(x: end.x, y: midY)
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
        .allowsHitTesting(linking == nil && draggingID == nil)
    }

    private func nodeView(_ node: WorkflowNode) -> some View {
        let selected = model.selectedNodeID == node.id
        let step = run?.steps.first(where: { $0.nodeID == node.id })
        return WorkflowNodeCard(node: node, selected: selected, step: step)
            .overlay(alignment: .top) {
                port(inPort: true, node: node, when: .ok)
                    .offset(y: -WorkflowNodeMetrics.port)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: node.kind == .loop ? 18 : 28) {
                    port(inPort: false, node: node, when: .ok)
                    if node.kind == .loop {
                        port(inPort: false, node: node, when: .always)
                    }
                    port(inPort: false, node: node, when: .error)
                }
                .offset(y: WorkflowNodeMetrics.port)
            }
            .onTapGesture { handleNodeTap(node) }
            .highPriorityGesture(nodeDrag(node))
            .position(
                x: node.x + WorkflowNodeMetrics.width / 2,
                y: node.y + WorkflowNodeMetrics.height / 2
            )
    }

    private func addButton(for node: WorkflowNode) -> some View {
        Button("Add step", .create) {
            model.selectNode(node.id)
            addingAfter = node.id
        }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .popover(isPresented: Binding(
                get: { addingAfter == node.id },
                set: { if !$0 { addingAfter = nil } }
            ), arrowEdge: .bottom) {
                WorkflowAddMenu(model: model) {
                    addingAfter = nil
                }
            }
            .position(
                x: node.x + WorkflowNodeMetrics.width / 2,
                y: node.y + WorkflowNodeMetrics.height + 22
            )
    }

    private func showsAdd(for node: WorkflowNode, in graph: WorkflowGraph) -> Bool {
        if draggingID != nil || linking != nil { return false }
        if model.selectedNodeID == node.id { return true }
        let maxY = graph.nodes.map(\.y).max() ?? node.y
        return node.y == maxY
    }

    @ViewBuilder
    private func port(inPort: Bool, node: WorkflowNode, when: WorkflowEdgeWhen) -> some View {
        let tint = inPort ? Theme.accent : portTint(when)
        let armedHere = !inPort && armed?.from == node.id && armed?.when == when
        let dot = Circle()
            .fill(armedHere ? tint : Theme.panel)
            .overlay(Circle().strokeBorder(tint.opacity(armedHere ? 1 : 0.85), lineWidth: 1.5))
            .frame(width: WorkflowNodeMetrics.port * 2, height: WorkflowNodeMetrics.port * 2)
            .contentShape(Circle().scale(1.8))
            .accessibilityLabel(portLabel(inPort: inPort, node: node, when: when))
            .help(inPort ? "Input" : portHelp(when))
        if inPort {
            dot.onTapGesture { completeArmed(to: node.id) }
        } else {
            dot.highPriorityGesture(linkGesture(from: node, when: when))
                .onTapGesture { arm(from: node.id, when: when) }
        }
    }

    private func portHelp(_ when: WorkflowEdgeWhen) -> String {
        switch when {
        case .ok: return "Drag or click, then click the next card. On success."
        case .error: return "Drag or click, then click the next card. On error."
        case .always: return "Drag or click, then click the next card. After the last pass."
        }
    }

    private func portLabel(inPort: Bool, node: WorkflowNode, when: WorkflowEdgeWhen) -> String {
        if inPort { return "Input of \(node.displayTitle)" }
        switch when {
        case .ok: return "On success of \(node.displayTitle)"
        case .error: return "On error of \(node.displayTitle)"
        case .always: return "After the last pass of \(node.displayTitle)"
        }
    }

    private func handleNodeTap(_ node: WorkflowNode) {
        if armed != nil {
            completeArmed(to: node.id)
            return
        }
        model.selectNode(node.id)
    }

    private func arm(from: String, when: WorkflowEdgeWhen) {
        armed = ArmedLink(from: from, when: when)
        model.selectNode(from)
    }

    private func completeArmed(to: String) {
        guard let armed else { return }
        if armed.from != to {
            model.connect(from: armed.from, to: to, when: armed.when)
        }
        self.armed = nil
    }

    private func nodeDrag(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingID != node.id {
                    model.beginNodeMove()
                    model.selectNode(node.id)
                    dragOrigin = CGPoint(x: node.x, y: node.y)
                    draggingID = node.id
                    armed = nil
                }
                guard let origin = dragOrigin else { return }
                model.moveNode(
                    id: node.id,
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
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

    private func linkGesture(from node: WorkflowNode, when: WorkflowEdgeWhen) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = outPort(node, when: when)
                let current = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                linking = PortDrag(from: node.id, start: start, current: current, when: when)
                armed = nil
            }
            .onEnded { value in
                let start = outPort(node, when: when)
                let current = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                if hypot(value.translation.width, value.translation.height) < 4 {
                    arm(from: node.id, when: when)
                } else if let target = hitInPort(current), target != node.id {
                    model.connect(from: node.id, to: target, when: when)
                }
                linking = nil
            }
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
        CGPoint(x: node.x + WorkflowNodeMetrics.width / 2, y: node.y)
    }

    private func outPort(_ node: WorkflowNode, when: WorkflowEdgeWhen) -> CGPoint {
        let inset: CGFloat
        if node.kind == .loop {
            switch when {
            case .ok: inset = -36
            case .always: inset = 0
            case .error: inset = 36
            }
        } else if when == .always {
            inset = 0
        } else {
            inset = when == .error ? 22 : -22
        }
        return CGPoint(
            x: node.x + WorkflowNodeMetrics.width / 2 + inset,
            y: node.y + WorkflowNodeMetrics.height
        )
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

    private func portTint(_ when: WorkflowEdgeWhen) -> Color {
        switch when {
        case .ok: return Theme.success
        case .error: return Theme.danger
        case .always: return Theme.secondary
        }
    }

    private func edgeTint(_ edge: WorkflowEdge) -> Color {
        if let step = run?.steps.first(where: { $0.nodeID == edge.from }),
           step.status == "ok" || step.status == "error" {
            return Theme.accent.opacity(0.85)
        }
        return portTint(edge.when).opacity(0.75)
    }

    private func edgeHit(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let midY = (start.y + end.y) / 2
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
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
        let maxX = CGFloat(graph.nodes.map { $0.x + Double(WorkflowNodeMetrics.width) }.max() ?? 228)
        let maxY = CGFloat(graph.nodes.map { $0.y + Double(WorkflowNodeMetrics.height) }.max() ?? 120)
        let width = max(maxX - minX, 1) + pad * 2
        let height = max(maxY - minY, 1) + pad * 2
        // Fit only ever zooms out. A blank draft is one card in a large window,
        // so fitting it to the glass magnified it past 200% and opened the
        // editor on a wall of one node. Anything that already fits is shown at
        // its own size, which is what a canvas opening at "normal" means.
        let z = min(1, max(0.4, min(canvasSize.width / width, canvasSize.height / height)))
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

private struct ArmedLink {
    var from: String
    var when: WorkflowEdgeWhen
}

/// Card on the canvas. Mark, title, subtitle, status when a run is live.
struct WorkflowNodeCard: View {
    let node: WorkflowNode
    var selected: Bool
    var step: WorkflowStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Theme.Space.s) {
                if node.kind == .agent, let backend = node.backend {
                    HarnessMark(id: backend, size: 22)
                } else {
                    FeatureMark(name: node.kind.mark, tint: ring, size: 22)
                }
                Text(node.kind.label)
                    .font(Theme.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(node.displayTitle)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(node.subtitle)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let step {
                StatusPill(status: step.status, text: step.endedLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: WorkflowNodeMetrics.width, height: WorkflowNodeMetrics.height, alignment: .topLeading)
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

/// Compact palette used by the + under a card.
struct WorkflowAddMenu: View {
    @Bindable var model: WorkflowsModel
    var onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tile(title: "Input", subtitle: "Starting prompt", mark: "mark_todo") {
                model.addNode(kind: .input)
            }
            ForEach(model.pickerBackends()) { backend in
                Button {
                    model.addNode(kind: .agent, backend: backend.id)
                    onPick()
                } label: {
                    row(title: backend.label, subtitle: "Agent") {
                        HarnessMark(id: backend.id, size: 18)
                    }
                }
                .buttonStyle(.plain)
            }
            tile(title: "HTTP", subtitle: "Host-owned request", mark: "mark_sync") {
                model.addNode(kind: .http)
            }
            tile(title: "Command", subtitle: "Shell in the folder", mark: "mark_terminal") {
                model.addNode(kind: .command)
            }
            tile(title: "Gate", subtitle: "Wait for you", mark: "mark_note") {
                model.addNode(kind: .gate)
            }
            tile(title: "If", subtitle: "Then or else", mark: "mark_plan") {
                model.addNode(kind: .condition)
            }
            tile(title: "Loop", subtitle: "Repeat a body", mark: "mark_scheduler") {
                model.addNode(kind: .loop)
            }
            ForEach(model.jobs) { job in
                Button {
                    model.addNode(kind: .automation, automationID: job.id)
                    onPick()
                } label: {
                    row(title: job.name, subtitle: "Run automation") {
                        FeatureMark(name: "mark_automation", tint: Theme.accent, size: 18)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private func tile(title: String, subtitle: String, mark: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onPick()
        } label: {
            row(title: title, subtitle: subtitle) {
                FeatureMark(name: mark, tint: Theme.accent, size: 18)
            }
        }
        .buttonStyle(.plain)
    }

    private func row<Leading: View>(
        title: String,
        subtitle: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .contentShape(.rect)
    }
}
#endif
