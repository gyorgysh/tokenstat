// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Repository choice, writing and setup stay local until an explicit Send.
/// The ordinary chat composer edits an isolated in-memory model, so starting
/// a conversation offers the same attachment and agent controls as continuing one.
struct ChatStartPage: View {
    @Bindable var draft: ChatStartDraft
    let repositories: [WorkspaceFolder]
    var isFullScreen = false
    var hostPicker: AnyView? = nil
    var allowsSend = true
    let onAdd: () -> Void
    let onSend: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ChatModel()
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var active = false
    @State private var backends: [ChatBackend] = []
    @State private var catalogLoading = false
    @State private var catalogError: String?
    @State private var catalogLease = UUID()
    @State private var dropTargeted = false
    @State private var composerDropTargeted = false
    @State private var touches: [ChatStartLiquidTouch] = []
    @State private var pointer: CGPoint?
    @State private var lastPointerUpdate = 0.0
    @State private var agentPickerFocused = false
    private struct CatalogOwner: Equatable {
        var owner: ChatStartDraft.Owner?
        var repository: String?
    }
    private struct AdapterIdentity: Equatable {
        var owner: ChatStartDraft.Owner?
        var reference: WorkReference?
        var agent: ChatStartDraft.AgentChoice?
    }
    private var catalogOwner: CatalogOwner { CatalogOwner(owner: draft.owner, repository: selected?.id) }
    private var adapterIdentity: AdapterIdentity { .init(owner: draft.owner, reference: draft.attachmentReference, agent: draft.agent) }
    private var backend: ChatBackend? { backends.first { $0.id == draft.agent?.backend && $0.installed != false } }
    private var selected: WorkspaceFolder? { repositories.first { $0.id == draft.repositoryID } }
    private var acceptsDrops: Bool {
        guard let owner = draft.owner else { return false }
        return active && !draft.isSubmitting && draft.attachmentReference != nil
            && owner.scope == WorkSessionContext.shared.scope && owner.session == WorkSessionContext.shared.generation
    }

    var body: some View {
        ZStack {
            ChatStartLiquidSurface(touches: touches, pointer: pointer, isFullScreen: isFullScreen,
                                   active: active && !agentPickerFocused && scenePhase == .active)
            ScrollView {
                VStack(spacing: 26) {
                    introduction
                    composer
                    if repositories.isEmpty {
                        Text(L10n.text("common.new_chat.empty")).font(Theme.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let error = draft.error ?? catalogError {
                        Text(error).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 700)
                .anchorPreference(key: ChatStartContentAnchor.self, value: .bounds) { $0 }
                .padding(.horizontal, 24).padding(.vertical, 70)
                .frame(maxWidth: .infinity)
            }
            .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
            .blur(radius: agentPickerFocused && !reduceTransparency ? 7 : 0)
            .overlay {
                if agentPickerFocused {
                    Theme.background.opacity(reduceTransparency ? 0.70 : 0.30).allowsHitTesting(false)
                }
            }
            if acceptsDrops && (dropTargeted || composerDropTargeted) { ChatDropExperience() }
        }
        .overlayPreferenceValue(ChatStartContentAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let excluded = geometry[anchor].insetBy(dx: -12, dy: -12)
                    ChatStartEmptySpace(excluded: excluded, tap: displaceLiquid, hover: moveLiquid)
                        .allowsHitTesting(active && !agentPickerFocused)
                }
            }
        }
        .environment(\.chatAgentPickerFocus, { focused in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { agentPickerFocused = focused }
            pointer = nil
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
        .onAppear { active = true; synchronizeComposer() }
        .onDisappear { active = false; catalogLease = UUID(); touches = []; pointer = nil; agentPickerFocused = false }
        .onChange(of: adapterIdentity) { _, _ in synchronizeComposer() }
        .onChange(of: draft.text) { _, text in if model.draft != text { model.draft = text } }
        .onChange(of: draft.attachments) { _, _ in synchronizeComposer() }
        .onChange(of: allowsSend) { _, _ in updateAvailability() }
        .onChange(of: draft.isSubmitting) { _, _ in updateAvailability() }
        .task(id: catalogOwner) { await loadCatalog() }
    }

    private var introduction: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle").font(Theme.font(29, weight: .light)).foregroundStyle(Theme.accent)
            Text(L10n.text("common.new_chat.title"))
                .font(Theme.font(34, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("common.new_chat.subtitle"))
                .font(Theme.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let chat = model.selected {
                #if os(macOS)
                ChatComposer(model: model, chat: chat, draft: $model.draft, selection: $selection,
                    attachments: model.attachments, previews: model.attachmentPreviews, running: false,
                    placeholder: L10n.text("common.new_chat.prompt"), onSend: onSend, onStop: {},
                    onAttach: attach, onRemove: { model.removeAttachment($0) }, acceptsDrops: acceptsDrops,
                    onDropProviders: receive, onDropTargeted: { composerDropTargeted = $0 })
                #else
                ClientChatComposer(model: model, chat: chat, draft: $model.draft,
                    attachments: model.attachments, previews: model.attachmentPreviews, running: false,
                    placeholder: L10n.text("common.new_chat.prompt"), onSend: onSend, onStop: {},
                    onAttach: attach, onRemove: { model.removeAttachment($0) }, onOpenSetup: {},
                    onImportURLs: { urls, owner in receive(ChatInbox.drops(from: urls), owner: owner) },
                    onDropURLs: { urls in receiveCurrent(ChatInbox.drops(from: urls)) },
                    onDropText: { strings in receiveCurrent(strings.map(ChatInboxDrop.text)) },
                    onDropData: { data in receiveCurrent(data.compactMap(ChatInbox.imageDrop(from:))) },
                    onDropTargeted: { composerDropTargeted = $0 })
                #endif
            }
            HStack(spacing: 12) {
                if let hostPicker { hostPicker }
                repositoryPicker
                Spacer(minLength: 0)
                if catalogLoading { ProgressView().controlSize(.small) }
                if catalogError != nil {
                    Button(L10n.text("common.retry"), systemImage: "arrow.clockwise") { Task { await loadCatalog() } }
                        .font(Theme.caption).disabled(catalogLoading)
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border))
        .shadow(color: Theme.accent.opacity(0.06), radius: 35, y: 12)
        .disabled(draft.isSubmitting)
    }

    private func synchronizeComposer() {
        let peer = selected.map { WorkDestinationResolver.route(folderID: $0.id).peer } ?? nil
        model.configureLanding(draft, backends: backends, peer: peer)
        updateAvailability()
    }

    private func updateAvailability() {
        model.landingCanSubmit = allowsSend && selected != nil && backend != nil && !catalogLoading
    }

    private func loadCatalog() async {
        let requested = catalogOwner
        let lease = UUID()
        catalogLease = lease
        catalogLoading = false; backends = []; catalogError = nil
        synchronizeComposer()
        guard let owner = requested.owner, let repository = requested.repository else { return }
        catalogLoading = true; updateAvailability()
        defer { if catalogLease == lease { catalogLoading = false; synchronizeComposer() } }
        let peer = WorkDestinationResolver.route(folderID: repository).peer
        do {
            let available = try await Bridge.chatBackends(peer: peer)
            guard !Task.isCancelled, active, catalogLease == lease, catalogOwner == requested,
                  WorkSessionContext.shared.scope == owner.scope, WorkSessionContext.shared.generation == owner.session else { return }
            backends = available
            if let choice = draft.agent, let descriptor = available.first(where: { $0.id == choice.backend && $0.installed != false }) {
                if let selectedModel = choice.model, !descriptor.models.contains(selectedModel) { draft.agent?.model = nil }
                if let effort = choice.effort, !descriptor.efforts.contains(effort) { draft.agent?.effort = nil }
                if descriptor.gateTier == "bypassOnly" { draft.agent?.autonomy = "bypass" }
            } else { draft.agent = ChatModel.newChatDefaults(backends: available) }
            if draft.agent == nil {
                catalogError = L10n.text("apple.chatsetupheader.no_agents_installed_set_up_an_agent_to_sta.2f73b57f")
            }
        } catch {
            guard !Task.isCancelled, active, catalogLease == lease, catalogOwner == requested else { return }
            // Keep the previous repository's setup for a retry. A failed
            // catalog is unavailable, rather than evidence it was uninstalled.
            catalogError = error.localizedDescription
        }
    }

    private func attach(_ item: ChatInboxItem, owner: WorkReference) async {
        guard active, !Task.isCancelled, owner == draft.attachmentReference else {
            if let file = item.file { try? FileManager.default.removeItem(at: file) }
            return
        }
        await model.attach(item, to: owner)
    }

    @discardableResult private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrops, !providers.isEmpty, let owner = draft.attachmentReference else { return false }
        Task { receive(await ChatInbox.drops(from: providers), owner: owner) }
        return true
    }

    private func receiveCurrent(_ drops: [ChatInboxDrop]) {
        guard let owner = draft.attachmentReference else { discard(drops); return }
        receive(drops, owner: owner)
    }

    private func receive(_ drops: [ChatInboxDrop], owner: WorkReference) {
        Task {
            defer { discard(drops) }
            for drop in drops {
                guard acceptsDrops, !Task.isCancelled, owner == draft.attachmentReference else { return }
                switch drop {
                case .attachment(let item): await attach(item, owner: owner)
                case .text(let text): model.draft += text
                case .folder: draft.error = L10n.text("apple.chatview.attach_files_not_folders.9039f9a4")
                }
            }
        }
    }

    private func discard(_ drops: [ChatInboxDrop]) {
        for case .attachment(let item) in drops { if let file = item.file { try? FileManager.default.removeItem(at: file) } }
    }

    private func displaceLiquid(at point: CGPoint) {
        guard active, !agentPickerFocused, !reduceMotion, !dimFlashingLights, scenePhase == .active else { return }
        let touch = ChatStartLiquidTouch(point: point)
        touches = Array(touches.suffix(2)) + [touch]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            touches.removeAll { $0.id == touch.id }
        }
    }

    private func moveLiquid(to point: CGPoint?) {
        guard active, !agentPickerFocused, !reduceMotion, !dimFlashingLights, scenePhase == .active else {
            if pointer != nil { pointer = nil }
            return
        }
        guard let point else { pointer = nil; return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPointerUpdate >= 1 / 30,
              pointer.map({ hypot($0.x - point.x, $0.y - point.y) >= 3 }) ?? true else { return }
        lastPointerUpdate = now
        pointer = point
    }

    private var repositoryPicker: some View {
        Menu {
            ForEach(repositories) { repository in
                Button { draft.repositoryID = repository.id } label: {
                    Label(repository.machineLabel.map { "\(repository.name) · \($0)" } ?? repository.name,
                          systemImage: repository.id == draft.repositoryID ? "checkmark" : "folder")
                }.help(repository.path)
            }
            Button(L10n.text("common.new_chat.add_repository"), systemImage: "folder.badge.plus", action: onAdd)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(Theme.accent)
                Text(selected?.name ?? L10n.text("common.new_chat.choose_repository")).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(Theme.caption)
            }
            .font(Theme.callout).padding(.horizontal, 10).frame(minHeight: 44)
            .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .accessibilityLabel(L10n.text("common.new_chat.repository"))
        .accessibilityValue(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
    }
}

/// Resolving the content anchor in this overlay avoids mixed window/local
/// coordinates. The even-odd hit shape contains only empty background: native
/// text fields, menus, popovers and the whole composer never receive this gesture.
private struct ChatStartContentAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct ChatStartEmptyShape: Shape {
    let excluded: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let hole = excluded.intersection(rect)
        if !hole.isNull { path.addRect(hole) }
        return path
    }
}

private struct ChatStartEmptySpace: View {
    let excluded: CGRect
    let tap: (CGPoint) -> Void
    let hover: (CGPoint?) -> Void
    var body: some View {
        Color.clear
            .contentShape(ChatStartEmptyShape(excluded: excluded), eoFill: true)
            .onTapGesture(coordinateSpace: .local) { point in
                guard !excluded.contains(point) else { return }
                tap(point)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover(excluded.contains(point) ? nil : point)
                case .ended: hover(nil)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct ChatStartLiquidTouch: Identifiable {
    let id = UUID()
    let point: CGPoint
    let began = Date.timeIntervalSinceReferenceDate
}

/// The native sidebar backdrop sits beneath an ink-like wash. Interaction
/// pushes that wash aside, exposing actual frosted glass rather than drawing
/// a ring over a solid plate. All decoration lives behind the writing surface.
private struct ChatStartLiquidSurface: View {
    let touches: [ChatStartLiquidTouch]
    let pointer: CGPoint?
    let isFullScreen: Bool
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var animates: Bool { active && !reduceMotion && !dimFlashingLights }

    var body: some View {
        ZStack {
            glass
            TimelineView(.animation(minimumInterval: touches.isEmpty && pointer == nil ? 1 / 12 : 1 / 45, paused: !animates)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let phase = animates ? now / 15 : 0
                ZStack {
                    ZStack {
                        Theme.background.opacity(colorScheme == .dark ? 0.91 : 0.86)
                        ambient(phase: phase)
                    }
                    .mask { displacementMask(now: now) }
                    caustics(now: now)
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private var glass: some View {
        if reduceTransparency { Theme.background }
        else {
            #if os(macOS)
            if #available(macOS 26, *) {
                SidebarGlassSurface(isFullScreen: isFullScreen, cornerRadius: 0)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
            #else
            Rectangle().fill(.ultraThinMaterial)
            #endif
        }
    }

    private func ambient(phase: Double) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                let a = CGPoint(x: size.width * (0.28 + sin(phase) * 0.08), y: size.height * 0.48)
                let b = CGPoint(x: size.width * (0.72 + cos(phase * 0.8) * 0.07), y: size.height * 0.64)
                glow(context: &context, at: a, radius: min(640, size.width * 0.65), color: Theme.accent, opacity: 0.22)
                glow(context: &context, at: b, radius: min(470, size.width * 0.5), color: Theme.secondary, opacity: 0.12)
                glow(context: &context, at: CGPoint(x: size.width * 0.53, y: size.height * 0.27), radius: min(420, size.width * 0.42), color: Theme.accent, opacity: 0.08)
            }
        }
    }

    private func displacementMask(now: Double) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            guard !reduceMotion, !dimFlashingLights else { return }
            context.blendMode = .destinationOut
            if let pointer, active {
                glow(context: &context, at: pointer, radius: 170, color: .white, opacity: 0.74)
            }
            for touch in touches {
                let age = max(0, now - touch.began)
                guard age < 3.1 else { continue }
                let growth = 1 - pow(1 - min(1, age / 1.5), 3)
                let fade = min(1, max(0, (3.1 - age) / 1.3))
                let radius = 52 + 330 * growth
                // Overlapping soft lenses form an asymmetric liquid opening;
                // their centers separate and settle as the wash flows back.
                clearPool(context: &context, at: touch.point, radius: radius, opacity: 0.98 * fade)
                let shifted = CGPoint(x: touch.point.x + radius * 0.24, y: touch.point.y - radius * 0.16)
                glow(context: &context, at: shifted, radius: radius * 0.71, color: .white, opacity: 0.54 * fade)
            }
        }
    }

    private func caustics(now: Double) -> some View {
        Canvas { context, _ in
            guard !reduceMotion, !dimFlashingLights else { return }
            if let pointer, active {
                glow(context: &context, at: CGPoint(x: pointer.x - 78, y: pointer.y + 48), radius: 115, color: Theme.accent, opacity: 0.14)
                glow(context: &context, at: CGPoint(x: pointer.x + 92, y: pointer.y - 40), radius: 100, color: Theme.secondary, opacity: 0.10)
            }
            for touch in touches {
                let age = max(0, now - touch.began)
                guard age < 3.1 else { continue }
                let growth = 1 - pow(1 - min(1, age / 1.5), 3)
                let fade = min(1, max(0, (3.1 - age) / 1.3))
                let radius = 52 + 330 * growth
                // Offset light catches the displaced mist in broad folds.
                // There is no stroked circle or repeated pulse.
                let a = CGPoint(x: touch.point.x - radius * 0.72, y: touch.point.y + radius * 0.28)
                let b = CGPoint(x: touch.point.x + radius * 0.63, y: touch.point.y - radius * 0.46)
                glow(context: &context, at: a, radius: radius * 0.74, color: Theme.accent, opacity: 0.34 * fade)
                glow(context: &context, at: b, radius: radius * 0.59, color: Theme.secondary, opacity: 0.21 * fade)
                glow(context: &context, at: CGPoint(x: b.x - 20, y: b.y + 12), radius: radius * 0.19, color: .white, opacity: 0.08 * fade)
                foldedLight(context: &context, at: touch.point, radius: radius * 0.79, phase: growth, opacity: fade)
            }
        }
    }

    /// A broad clear center and a soft, irregular edge read as a displaced
    /// film. A simple Gaussian hole would only look like another blurry glow.
    private func clearPool(context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, opacity: Double) {
        context.drawLayer { lens in
            lens.translateBy(x: center.x, y: center.y)
            lens.scaleBy(x: 1, y: 0.84)
            let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            lens.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(stops: [.init(color: .white.opacity(opacity), location: 0),
                                 .init(color: .white.opacity(opacity * 0.95), location: 0.52),
                                 .init(color: .white.opacity(opacity * 0.26), location: 0.83),
                                 .init(color: .white.opacity(0), location: 1)]),
                center: .zero, startRadius: 0, endRadius: radius))
        }
    }

    /// Soft folds catch light at the edge of the moving mist. Filled,
    /// tapered ribbons avoid the outlined-ring appearance of a ripple.
    private func foldedLight(context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, phase: Double, opacity: Double) {
        for side in [0.0, Double.pi] {
            var outside: [CGPoint] = [], inside: [CGPoint] = []
            for index in 0...42 {
                let t = Double(index) / 42
                let angle = -1.1 + t * 1.65 + side
                let r = radius * (1 + 0.12 * sin(angle * 3 + phase * 2) + 0.06 * cos(angle * 5 - phase))
                let width = radius * 0.045 * sin(t * .pi)
                outside.append(CGPoint(x: center.x + cos(angle) * (r + width), y: center.y + sin(angle) * (r + width) * 0.77))
                inside.append(CGPoint(x: center.x + cos(angle) * (r - width), y: center.y + sin(angle) * (r - width) * 0.77))
            }
            var fold = Path()
            fold.addLines(outside + inside.reversed()); fold.closeSubpath()
            context.drawLayer { light in
                light.addFilter(.blur(radius: 13))
                light.fill(fold, with: .linearGradient(
                    Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.24 * opacity),
                                      Theme.secondary.opacity(0.15 * opacity), Theme.secondary.opacity(0)]),
                    startPoint: outside.first ?? center, endPoint: outside.last ?? center))
            }
        }
    }

    private func glow(context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color, opacity: Double) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(stops: [.init(color: color.opacity(opacity), location: 0),
                             .init(color: color.opacity(opacity * 0.70), location: 0.42),
                             .init(color: color.opacity(0), location: 1)]),
            center: center, startRadius: 0, endRadius: radius))
    }
}
