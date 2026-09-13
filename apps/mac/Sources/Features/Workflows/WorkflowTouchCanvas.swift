// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Wide-iPad touch canvas for the workflow editor. The phone keeps the
/// step list; this canvas is the pointer-and-finger counterpart with the
/// same document, validation and inspector.
///
/// Add, select, move, connect, pan, zoom and fit all work by touch. The
/// list stays available beside it as the accessible alternate, and every
/// selection still edits in the inspector.
struct WorkflowTouchCanvas: View {
    @Bindable var session: WorkflowEditorSession
    @Binding var stepPath: [String]
    @State private var pan = CGSize.zero
    @State private var panOrigin = CGSize.zero
    @State private var panning = false
    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat = 1
    @State private var magnifying = false
    @State private var linking: TouchLinkDrag?
    @State private var armed: TouchArmedLink?
    @State private var dragOrigin: CGPoint?
    @State private var draggingID: String?
    @State private var showingAdd = false
    @State private var canvasSize: CGSize = .zero
    @State private var hasFitted = false
    @Namespace private var viewport

    private var nodes: [WorkflowNode] { session.fields.nodes }
    private var edges: [WorkflowEdge] { session.fields.edges }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            toolbar
            if let armed {
                linkBanner(armed)
            }
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.border)
                )
            hint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingAdd) {
            TouchAddSheet(session: session, stepPath: $stepPath) {
                showingAdd = false
            }
            .presentationDetents([.medium])
        }
        .disabled(!session.loaded || session.working || session.creating)
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Canvas")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
                Text("\(nodes.count) steps · \(edges.count) connections")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: 0)
            Button("Undo", .restore) { undo() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!session.canUndoGraph)
            Button("Redo", .next) { redo() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!session.canRedoGraph)
            Button("Fit", .layout) { fit() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Text("\(Int((zoom * 100).rounded()))%")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
                .accessibilityLabel("Zoom \(Int((zoom * 100).rounded())) percent")
            Button("Add step", .create) { showingAdd = true }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(session.additionIssue(kind: .gate) != nil)
        }
    }

    private func linkBanner(_ armed: TouchArmedLink) -> some View {
        let source = nodes.first { $0.id == armed.from }
        let role = WorkflowGraphRules.outgoingRole(kind: source?.kind ?? .agent, when: armed.when)
        return HStack(alignment: .center, spacing: Theme.Space.s) {
            Text("Choose the next step for \(role). Tap a card or its top dot.")
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel", .dismiss) { self.armed = nil }
                .buttonStyle(SecondaryButtonStyle(small: true))
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Space.s))
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.background
                    .contentShape(.rect)
                    .gesture(canvasPan)
                    .onTapGesture { deselect() }
                TouchGrid(zoom: zoom, pan: pan)
                    .allowsHitTesting(false)
                contentStack
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width, y: pan.height)
            .simultaneousGesture(canvasZoom)
            .onAppear {
                canvasSize = geo.size
                fitIfNeeded()
            }
            .onChange(of: geo.size) { _, size in
                let first = canvasSize.width < 1
                canvasSize = size
                if first { fitIfNeeded() }
            }
            .onChange(of: session.fields.nodes.map(\.id)) { _, _ in
                fitIfNeeded()
            }
        }
        .background(Theme.background)
        .overlay(alignment: .topLeading) { emptyHint }
        .coordinateSpace(name: viewport)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow canvas. \(nodes.count) steps.")
    }

    private var contentStack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                if let from = nodes.first(where: { $0.id == edge.from }),
                   let to = nodes.first(where: { $0.id == edge.to }) {
                    let start = outPort(from, when: edge.when)
                    let end = inPort(to)
                    let selected = session.selectedConnectionID == edge.id
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
                        selected ? Theme.accent : edgeTint(edge.when),
                        style: StrokeStyle(lineWidth: selected ? 2.5 : 1.6, lineCap: .round)
                    )
                    .contentShape(edgeHit(from: start, to: end))
                    .onTapGesture { selectEdge(edge.id) }
                    .allowsHitTesting(linking == nil && draggingID == nil)
                }
            }
            if let linking {
                Path { path in
                    path.move(to: linking.start)
                    path.addLine(to: linking.current)
                }
                .stroke(portTint(linking.when), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .allowsHitTesting(false)
            }
            ForEach(nodes) { node in
                touchNode(node)
            }
        }
    }

    private func touchNode(_ node: WorkflowNode) -> some View {
        let selected = session.selectedStepID == node.id
        return WorkflowTouchNodeCard(node: node, selected: selected)
            .overlay(alignment: .top) {
                TouchPortDot(tint: Theme.accent, label: "Input of \(node.displayTitle)")
                    .offset(y: -7)
                    .onTapGesture { completeArmed(to: node.id) }
            }
            .overlay(alignment: .bottom) {
                // Spacing matches `outPort`: Then/On error sit ±22 from
                // center, loop Body/After/On error at -36/0/+36.
                HStack(spacing: node.kind == .loop ? 22 : 30) {
                    TouchPortDot(tint: portTint(.ok), label: touchPortLabel(node: node, when: .ok))
                        .highPriorityGesture(linkGesture(from: node, when: .ok))
                        .onTapGesture { arm(from: node.id, when: .ok) }
                    if node.kind == .loop {
                        TouchPortDot(tint: portTint(.always), label: touchPortLabel(node: node, when: .always))
                            .highPriorityGesture(linkGesture(from: node, when: .always))
                            .onTapGesture { arm(from: node.id, when: .always) }
                    }
                    TouchPortDot(tint: portTint(.error), label: touchPortLabel(node: node, when: .error))
                        .highPriorityGesture(linkGesture(from: node, when: .error))
                        .onTapGesture { arm(from: node.id, when: .error) }
                }
                .offset(y: 7)
            }
            .onTapGesture { selectNode(node.id) }
            .highPriorityGesture(nodeDrag(node))
            .position(
                x: node.x + WorkflowTouchViewport.cardWidth / 2,
                y: node.y + WorkflowTouchViewport.cardHeight / 2
            )
            // One VoiceOver stop per card. The port dots are touch-and-pointer
            // affordances; full VoiceOver editing lives in List mode, which
            // edits this same document.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(node.kind.label). \(node.displayTitle). \(node.subtitle)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    @ViewBuilder
    private var emptyHint: some View {
        if nodes.count <= 1 || edges.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("The run goes top to bottom")
                    .font(Theme.callout.weight(.medium))
                Text("Drag a card to move it. Drag a bottom dot to the next card, or tap a dot then a card. Fit is in the toolbar.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            .padding(12)
            .allowsHitTesting(false)
        }
    }

    private var hint: some View {
        Text("Canvas edits the same steps as the list. Selection opens in the inspector.")
            .font(Theme.caption)
            .foregroundStyle(Theme.controlGlyph)
    }

    private func touchPortLabel(node: WorkflowNode, when: WorkflowEdgeWhen) -> String {
        let role = WorkflowGraphRules.outgoingRole(kind: node.kind, when: when)
        return "\(role) of \(node.displayTitle)"
    }

    private func selectNode(_ id: String) {
        if let armed {
            if armed.from != id {
                session.connectSteps(from: armed.from, to: id, when: armed.when)
            }
            self.armed = nil
            session.selectStep(id)
            session.selectConnection(nil)
            stepPath = [id]
            return
        }
        session.selectStep(id)
        session.selectConnection(nil)
        stepPath = [id]
    }

    private func selectEdge(_ id: String) {
        armed = nil
        session.selectConnection(id)
        stepPath = []
    }

    private func deselect() {
        session.selectStep(nil)
        session.selectConnection(nil)
        stepPath = []
        armed = nil
    }

    private func undo() {
        armed = nil
        session.undoGraph()
        syncPath()
    }

    private func redo() {
        armed = nil
        session.redoGraph()
        syncPath()
    }

    private func syncPath() {
        if let id = session.selectedStepID,
           session.fields.nodes.contains(where: { $0.id == id }) {
            stepPath = [id]
        } else {
            stepPath = []
        }
    }

    private func arm(from: String, when: WorkflowEdgeWhen) {
        armed = TouchArmedLink(from: from, when: when)
        session.selectStep(from)
        session.selectConnection(nil)
        stepPath = [from]
    }

    private func completeArmed(to: String) {
        guard let armed else { return }
        if armed.from != to {
            session.connectSteps(from: armed.from, to: to, when: armed.when)
        }
        self.armed = nil
    }

    private func nodeDrag(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(viewport))
            .onChanged { value in
                if draggingID != node.id {
                    session.beginStepMove()
                    session.selectStep(node.id)
                    session.selectConnection(nil)
                    stepPath = [node.id]
                    dragOrigin = CGPoint(x: node.x, y: node.y)
                    draggingID = node.id
                    armed = nil
                }
                guard let origin = dragOrigin else { return }
                let point = WorkflowCanvasCoordinates.moved(from: origin, translation: value.translation, zoom: zoom)
                session.moveStep(id: node.id, x: point.x, y: point.y)
            }
            .onEnded { value in
                if let id = draggingID, let origin = dragOrigin {
                    let point = WorkflowCanvasCoordinates.moved(from: origin, translation: value.translation, zoom: zoom)
                    session.moveStep(
                        id: id,
                        x: WorkflowCanvasCoordinates.snapped(point.x),
                        y: WorkflowCanvasCoordinates.snapped(point.y)
                    )
                }
                draggingID = nil
                dragOrigin = nil
                syncPath()
            }
    }

    private func linkGesture(from node: WorkflowNode, when: WorkflowEdgeWhen) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(viewport))
            .onChanged { value in
                let start = outPort(node, when: when)
                let current = WorkflowCanvasCoordinates.moved(from: start, translation: value.translation, zoom: zoom)
                linking = TouchLinkDrag(from: node.id, start: start, current: current, when: when)
                armed = nil
            }
            .onEnded { value in
                let start = outPort(node, when: when)
                let current = WorkflowCanvasCoordinates.moved(from: start, translation: value.translation, zoom: zoom)
                if hypot(value.translation.width, value.translation.height) < 4 {
                    arm(from: node.id, when: when)
                } else if let target = hitInPort(current), target != node.id {
                    session.connectSteps(from: node.id, to: target, when: when)
                    session.selectStep(target)
                    session.selectConnection(nil)
                    stepPath = [target]
                }
                linking = nil
            }
    }

    private var canvasPan: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(viewport))
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

    private var canvasZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard draggingID == nil, linking == nil, !panning else { return }
                if !magnifying {
                    zoomOrigin = zoom
                    magnifying = true
                }
                zoom = WorkflowCanvasCoordinates.clampedZoom(zoomOrigin * value.magnification)
            }
            .onEnded { _ in
                magnifying = false
            }
    }

    private func inPort(_ node: WorkflowNode) -> CGPoint {
        CGPoint(x: node.x + WorkflowTouchViewport.cardWidth / 2, y: node.y)
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
            x: node.x + WorkflowTouchViewport.cardWidth / 2 + inset,
            y: node.y + WorkflowTouchViewport.cardHeight
        )
    }

    private func hitInPort(_ point: CGPoint) -> String? {
        nodes.first { node in
            WorkflowTouchViewport.hitsPort(touch: point, port: inPort(node))
        }?.id
    }

    private func portTint(_ when: WorkflowEdgeWhen) -> Color {
        switch when {
        case .ok: return Theme.success
        case .error: return Theme.danger
        case .always: return Theme.secondary
        }
    }

    private func edgeTint(_ when: WorkflowEdgeWhen) -> Color {
        portTint(when).opacity(0.75)
    }

    private func edgeHit(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let midY = (start.y + end.y) / 2
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
        return path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round))
    }

    private func fitIfNeeded() {
        // Fit once, when the graph and the canvas both have content. A
        // refit on every added step would steal a deliberate zoom or pan.
        guard !hasFitted, !nodes.isEmpty, canvasSize.width > 1, canvasSize.height > 1 else { return }
        hasFitted = true
        fit()
    }

    private func fit() {
        guard draggingID == nil, linking == nil, !panning else { return }
        let fit = WorkflowTouchViewport.fit(
            nodeOrigins: nodes.map { CGPoint(x: $0.x, y: $0.y) },
            canvasSize: canvasSize
        )
        zoom = fit.zoom
        pan = fit.pan
    }
}

private struct TouchArmedLink: Equatable {
    var from: String
    var when: WorkflowEdgeWhen
}

private struct TouchLinkDrag {
    var from: String
    var start: CGPoint
    var current: CGPoint
    var when: WorkflowEdgeWhen
}

/// Finger-sized port target. The visible dot stays small so the graph keeps
/// its hierarchy; layout stays 14 points while the tappable shape is a
/// full 44-point square around it.
private struct TouchPortDot: View {
    var tint: Color
    var label: String

    var body: some View {
        Circle()
            .fill(Theme.panel)
            .overlay(Circle().strokeBorder(tint.opacity(0.9), lineWidth: 2))
            .frame(width: 14, height: 14)
            .contentShape(Rectangle().inset(by: -15))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

private struct TouchGrid: View {
    var zoom: CGFloat
    var pan: CGSize

    var body: some View {
        Canvas { ctx, _ in
            let step: CGFloat = 24
            let z = max(zoom, 0.2)
            let left = floor(((-pan.width / z) - step) / step) * step
            let top = floor(((-pan.height / z) - step) / step) * step
            // The grid is decorative context, not content: cap the dot count
            // so a far zoom-out cannot mint thousands of dots.
            let maxDots = 4000
            var drawn = 0
            var x = left
            while x < left + 200 * step, drawn < maxDots {
                var y = top
                while y < top + 200 * step, drawn < maxDots {
                    let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.border))
                    drawn += 1
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// Card on the touch canvas. Mark, kind, title and subtitle mirror the Mac
/// card at the same 228×120 size so positions round-trip between devices.
private struct WorkflowTouchNodeCard: View {
    let node: WorkflowNode
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Theme.Space.s) {
                if node.kind == .agent, let backend = node.backend, !backend.isEmpty {
                    HarnessMark(id: backend, size: 22)
                } else {
                    FeatureMark(name: node.kind.mark, tint: Theme.accent, size: 22)
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
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: WorkflowTouchViewport.cardWidth, height: WorkflowTouchViewport.cardHeight, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.10 : 0.05), radius: selected ? 8 : 2, y: 1)
    }
}

/// When a canvas edge is selected the inspector edits that connection.
/// The role names match the step list: If uses Then/Else, Loop uses
/// Body/After last pass, everything else uses Then/On error/Always.
struct WorkflowConnectionInspector: View {
    @Bindable var session: WorkflowEditorSession
    @Binding var stepPath: [String]

    private var edge: WorkflowEdge? {
        guard let id = session.selectedConnectionID else { return nil }
        return session.fields.edges.first { $0.id == id }
    }

    var body: some View {
        if let edge {
            let source = session.fields.nodes.first { $0.id == edge.from }
            let target = session.fields.nodes.first { $0.id == edge.to }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Connection")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
                Text("\(source?.displayTitle ?? edge.from) → \(target?.displayTitle ?? edge.to)")
                    .font(Theme.callout.weight(.semibold))
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(WorkflowGraphRules.whenOptions(kind: source?.kind ?? .agent), id: \.value) { option in
                        ChoiceChip(title: option.label, isSelected: edge.when == option.value) {
                            session.updateSelectedConnection(when: option.value)
                        }
                    }
                }
                Text(WorkflowGraphRules.connectionCaption(kind: source?.kind ?? .agent))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s) {
                    Button("Remove connection", .delete, role: .destructive) {
                        session.removeConnection(id: edge.id)
                        stepPath = []
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    Spacer(minLength: 0)
                    Button("Done", .done) {
                        session.selectConnection(nil)
                        stepPath = []
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("This connection is no longer in the graph.")
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
        }
    }
}

/// Wide editor surface: the touch canvas or the step list. Phone keeps
/// the list; wide iPad defaults to the canvas with the list as the
/// accessible alternate.
enum WorkflowCanvasMode: String, CaseIterable, Hashable {
    case canvas = "Canvas"
    case list = "List"
}

/// Two-column kind palette. MCP is reserved on the host and never offered.
private struct TouchAddSheet: View {
    @Bindable var session: WorkflowEditorSession
    @Binding var stepPath: [String]
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ThemedSheet(title: "Add a step", subtitle: "Then connects from the selected step.", icon: .create, onClose: { dismiss() }) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)],
                spacing: Theme.Space.s
            ) {
                ForEach(choices, id: \.kind) { choice in
                    Button {
                        add(choice.kind)
                    } label: {
                        HStack(alignment: .center, spacing: Theme.Space.s) {
                            FeatureMark(name: choice.kind.mark, tint: Theme.accent, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title)
                                    .font(Theme.font(13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(choice.subtitle)
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.controlGlyph)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.title). \(choice.subtitle)")
                }
            }
            .padding(.top, Theme.Space.s)
        } actions: {
            Button("Done", .done) {
                onDone()
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
        }
    }

    private func add(_ kind: WorkflowNodeKind) {
        var backend: String?
        var automationID: String?
        if kind == .agent {
            backend = session.backends.defaultForPicker()?.id
        }
        if kind == .automation {
            automationID = session.jobs.first?.id
        }
        session.addStep(kind: kind, backend: backend, automationID: automationID)
        if let id = session.selectedStepID {
            stepPath = [id]
        }
        onDone()
        dismiss()
    }

    private var choices: [(kind: WorkflowNodeKind, title: String, subtitle: String)] {
        [
            (.input, "Start", "Starting prompt"),
            (.agent, "Agent", "Model and prompt"),
            (.automation, "Automation", "Run a saved job"),
            (.http, "HTTP", "Host-owned request"),
            (.command, "Command", "Shell in the folder"),
            (.gate, "Gate", "Wait for you"),
            (.condition, "If", "Then or else"),
            (.loop, "Loop", "Repeat a body"),
        ]
    }
}
