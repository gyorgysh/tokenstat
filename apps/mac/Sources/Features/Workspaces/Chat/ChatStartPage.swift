// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Repository choice, writing and setup stay local until an explicit Send.
/// The ordinary chat composer edits an isolated in-memory model, so starting
/// a conversation offers the same attachment and agent controls as continuing one.
struct ChatStartPage: View {
    @Bindable var draft: ChatStartDraft
    let repositories: [WorkspaceFolder]
    var hostPicker: AnyView? = nil
    var allowsSend = true
    let onAdd: () -> Void
    let onSend: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
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
    @State private var contentBounds = CGRect.zero
    @State private var ripple: ChatStartRipple?
    @State private var rippleExpanded = false
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
            background
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
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ChatStartBounds.self, value: geometry.frame(in: .named("chat-start")))
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 70)
                .frame(maxWidth: .infinity)
            }
            .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
            if acceptsDrops && (dropTargeted || composerDropTargeted) { ChatDropExperience() }
        }
        .coordinateSpace(name: "chat-start")
        .onPreferenceChange(ChatStartBounds.self) { contentBounds = $0 }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("chat-start")).onEnded { event in
            guard !contentBounds.contains(event.location) else { return }
            showRipple(at: event.location)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
        .onAppear { active = true; synchronizeComposer() }
        .onDisappear { active = false; catalogLease = UUID(); ripple = nil }
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

    private var background: some View {
        ZStack {
            Theme.background
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || dimFlashingLights || scenePhase != .active)) { context in
                let phase = reduceMotion || dimFlashingLights ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 12)
                Ellipse().fill(Theme.accent.opacity(0.09))
                    .frame(width: 620, height: 330).blur(radius: 85)
                    .offset(x: phase * 36, y: -90)
            }
            if let ripple {
                Circle().stroke(Theme.accent.opacity(rippleExpanded ? 0 : 0.17), lineWidth: rippleExpanded ? 1 : 3)
                    .frame(width: rippleExpanded ? 760 : 24, height: rippleExpanded ? 760 : 24)
                    .position(ripple.point)
                    .id(ripple.id)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
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

    private func showRipple(at point: CGPoint) {
        guard !reduceMotion, !dimFlashingLights, scenePhase == .active else { return }
        let wave = ChatStartRipple(point: point)
        rippleExpanded = false; ripple = wave
        Task { @MainActor in
            await Task.yield()
            guard ripple?.id == wave.id, active else { return }
            withAnimation(.easeOut(duration: 1.1)) { rippleExpanded = true }
            try? await Task.sleep(for: .seconds(1.15))
            if ripple?.id == wave.id { ripple = nil }
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

private struct ChatStartRipple { let id = UUID(); let point: CGPoint }
private struct ChatStartBounds: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
