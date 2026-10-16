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
    @State private var touches: [ChatStartGlassTouch] = []
    @State private var hoverMotion = ChatStartHoverMotion()
    @State private var wakes: [ChatStartGlassWake] = []
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
            ChatStartLiquidSurface(touches: touches, wakes: wakes, isFullScreen: isFullScreen,
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
            hoverMotion.point = nil
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
        .onAppear { active = true; synchronizeComposer() }
        .onDisappear { active = false; catalogLease = UUID(); touches = []; wakes = []; hoverMotion.reset(); agentPickerFocused = false }
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
        let touch = ChatStartGlassTouch(point: point)
        touches = Array(touches.suffix(3)) + [touch]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChatStartGlassField.touchLifetime))
            touches.removeAll { $0.id == touch.id }
        }
    }

    private func moveLiquid(to point: CGPoint?) {
        guard active, !agentPickerFocused, !reduceMotion, !dimFlashingLights, scenePhase == .active else {
            hoverMotion.point = nil
            return
        }
        guard let point else { hoverMotion.point = nil; return }
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - hoverMotion.lastPointerUpdate
        guard elapsed >= 1 / 45 else { return }
        defer { hoverMotion.lastPointerUpdate = now }
        guard let previous = hoverMotion.point, elapsed < 0.3 else { hoverMotion.point = point; return }
        // A low-pass pointer has some mass. Sparse motion impulses then keep
        // drifting after hover leaves; crossing into the composer adds none.
        let blend = 1 - exp(-min(0.1, elapsed) / 0.115)
        let smoothed = CGPoint(x: previous.x + (point.x - previous.x) * blend,
                               y: previous.y + (point.y - previous.y) * blend)
        hoverMotion.point = smoothed
        guard now - hoverMotion.lastWakeUpdate >= 0.20 else { return }
        let velocity = CGVector(dx: (smoothed.x - previous.x) / elapsed,
                                dy: (smoothed.y - previous.y) / elapsed)
        guard hypot(velocity.dx, velocity.dy) > 16 else { return }
        hoverMotion.lastWakeUpdate = now
        wakes.removeAll { now - $0.began >= ChatStartGlassField.wakeLifetime }
        wakes = Array(wakes.suffix(ChatStartGlassField.maximumWakes - 1))
        wakes.append(.init(point: smoothed, velocity: velocity, began: now))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChatStartGlassField.wakeLifetime))
            let expiration = Date.timeIntervalSinceReferenceDate
            wakes.removeAll { expiration - $0.began >= ChatStartGlassField.wakeLifetime }
        }
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

/// Hover samples are input history, not view state. Keeping each sample in
/// a plain reference avoids rebuilding the composer at pointer frequency;
/// only the bounded visual wake list publishes an update.
private final class ChatStartHoverMotion {
    var point: CGPoint?
    var lastWakeUpdate = 0.0
    var lastPointerUpdate = 0.0
    func reset() { point = nil; lastWakeUpdate = 0; lastPointerUpdate = 0 }
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

/// Native glass remains a complete, unmasked surface. Broad translucent
/// optical layers above it bend and settle with continuous inertial wakes.
private struct ChatStartLiquidSurface: View {
    let touches: [ChatStartGlassTouch]
    let wakes: [ChatStartGlassWake]
    let isFullScreen: Bool
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var elapsed = 0.0
    @State private var clockStarted: Double?

    private var animates: Bool { active && !reduceMotion && !dimFlashingLights }

    var body: some View {
        ZStack {
            glass
            TimelineView(.animation(minimumInterval: touches.isEmpty && wakes.isEmpty ? 1 / 24 : 1 / 60, paused: !animates)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let time = elapsed + (clockStarted.map { max(0, now - $0) } ?? 0)
                let accent = Theme.accent.resolve(in: environment)
                let secondary = Theme.secondary.resolve(in: environment)
                let background = Theme.background.resolve(in: environment)
                let palette = ChatStartGlassField.Palette(
                    background: .init(background.red, background.green, background.blue),
                    accent: .init(accent.red, accent.green, accent.blue),
                    secondary: .init(secondary.red, secondary.green, secondary.blue),
                    dark: colorScheme == .dark)
                Canvas(rendersAsynchronously: true) { context, size in
                    if let image = ChatStartGlassField.image(size: size, time: time,
                        now: now, touches: touches, wakes: wakes, palette: palette) {
                        context.addFilter(.blur(radius: 9))
                        context.draw(Image(decorative: image, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: size))
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { if animates { clockStarted = Date.timeIntervalSinceReferenceDate } }
        .onChange(of: animates) { _, running in
            let now = Date.timeIntervalSinceReferenceDate
            if let started = clockStarted { elapsed += max(0, now - started) }
            clockStarted = running ? now : nil
        }
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
}
