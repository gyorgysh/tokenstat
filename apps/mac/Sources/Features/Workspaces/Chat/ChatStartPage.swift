// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Repository choice, writing and setup stay local until an explicit Send.
/// The ordinary chat composer edits an isolated in-memory model, so starting
/// a conversation offers the same attachment and agent controls as continuing
/// one.
///
/// The repository choice comes first, and a disabled Send explains what is missing.
struct ChatStartPage: View {
    @Bindable var draft: ChatStartDraft
    let repositories: [WorkspaceFolder]
    var isFullScreen = false
    var titlebarDragHeight: CGFloat = 0
    var hostPicker: AnyView? = nil
    var allowsSend = true
    /// A mobile New Chat with known computers keeps the composer visible while
    /// the person chooses its computer and repository in the same place.
    var showsEmptyComposer = false
    var requiresHostSelection = false
    /// The repository list is still being read, so an empty one says nothing
    /// yet and the page must not offer first-run help on the strength of it.
    var repositoriesLoading = false
    let onAdd: () -> Void
    let onSend: () -> Void
    /// Adds dropped folders as repositories. Only offered where a folder can
    /// be dropped at all.
    var onAddFolders: (([URL]) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var folderDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var agentPickerFocused = false
    @State private var pointer = ChatStartPointer()
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
    private var remoteMachines: [(id: String, name: String)] {
        var seen = Set<String>()
        return repositories.compactMap { folder in
            guard folder.isRemote else { return nil }
            let id = folder.machineID ?? folder.machineLabel ?? folder.id
            guard seen.insert(id).inserted else { return nil }
            return (id, folder.machineLabel ?? L10n.text("apple.workspacesview.remote_machine.d9dd1af3"))
        }
    }
    private var writing: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Nothing to talk about yet. The page teaches the first steps instead
    /// of offering a composer that cannot send.
    private var needsRepository: Bool {
        !showsEmptyComposer && repositories.isEmpty && !repositoriesLoading && draft.text.isEmpty && draft.attachments.isEmpty
    }
    private var showsStarters: Bool {
        selected != nil && !writing && draft.attachments.isEmpty && !draft.isSubmitting
    }
    private var acceptsDrops: Bool {
        guard let owner = draft.owner, !needsRepository else { return false }
        return active && !draft.isSubmitting && draft.attachmentReference != nil
            && owner.scope == WorkSessionContext.shared.scope && owner.session == WorkSessionContext.shared.generation
    }

    var body: some View {
        ZStack {
            ChatStartBackdrop(isFullScreen: isFullScreen,
                              active: active && !agentPickerFocused && scenePhase == .active,
                              lift: writing, sending: draft.isSubmitting, pointer: pointer)
            GeometryReader { pane in
                ScrollView {
                    VStack(spacing: 26) {
                        introduction
                        if requiresHostSelection, let hostPicker {
                            HStack { hostPicker; Spacer(minLength: 0) }
                                .chatStartCard()
                        } else if needsRepository {
                            onboarding
                        } else {
                            composer
                            if showsStarters {
                                ChatStartStarters(onPick: { draft.text = $0 }, revealed: true)
                                    .padding(.top, -8)
                                    .transition(.opacity)
                            }
                        }
                        if let error = draft.error ?? catalogError {
                            Text(error).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    // Centre the content with a small upward optical bias.
                    .padding(.bottom, 48 + min(96, pane.size.height * 0.07))
                    .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .center)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsStarters)
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: needsRepository)
                // Keep short screens still while allowing long content to scroll.
                .scrollBounceBehavior(.basedOnSize)
            }
            .opacity(draft.isSubmitting ? 0 : 1)
            .scaleEffect(draft.isSubmitting && !reduceMotion ? 0.975 : 1)
            .accessibilityHidden(draft.isSubmitting)
            .allowsHitTesting(!draft.isSubmitting)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: draft.isSubmitting)
            .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
            .modifier(FolderDrop(enabled: needsRepository && onAddFolders != nil && active,
                                 isTargeted: $folderDropTargeted) { onAddFolders?($0) })
            .blur(radius: agentPickerFocused && !reduceTransparency ? 7 : 0)
            .overlay {
                if agentPickerFocused {
                    Theme.background.opacity(reduceTransparency ? 0.70 : 0.30).allowsHitTesting(false)
                }
            }
            if draft.isSubmitting, let began = draft.preparationStartedAt {
                ChatStartSendingView(startedAt: began, active: active && scenePhase == .active)
                    .transition(.opacity)
            }
            if acceptsDrops && (dropTargeted || composerDropTargeted) { ChatDropExperience() }
        }
        #if os(macOS)
        .overlay(alignment: .top) {
            if !isFullScreen && titlebarDragHeight > 0 {
                TitlebarDragArea()
                    .frame(height: titlebarDragHeight)
                    .accessibilityHidden(true)
            }
        }
        #endif
        .environment(\.chatAgentPickerFocus, { focused in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { agentPickerFocused = focused }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Plain state on the pointer object, so following the mouse redraws
        // nothing but the backdrop's own next frame.
        .onContinuousHover(coordinateSpace: .named(ChatStartBackdrop.space)) { phase in
            switch phase {
            case .active(let point): pointer.target = point
            case .ended: pointer.target = nil
            }
        }
        .coordinateSpace(name: ChatStartBackdrop.space)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: draft.isSubmitting)
        .clipped()
        .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
        .onAppear { active = true; synchronizeComposer(); chooseDefaultRepository() }
        .onChange(of: repositories.map(\.id)) { _, _ in chooseDefaultRepository() }
        .onChange(of: repositoriesLoading) { _, _ in chooseDefaultRepository() }
        .onChange(of: draft.owner) { _, _ in chooseDefaultRepository() }
        .onDisappear {
            active = false; catalogLease = UUID(); agentPickerFocused = false
        }
        .onChange(of: adapterIdentity) { _, _ in synchronizeComposer() }
        .onChange(of: draft.text) { _, text in if model.draft != text { model.draft = text } }
        .onChange(of: draft.attachments) { _, _ in synchronizeComposer() }
        .onChange(of: allowsSend) { _, _ in updateAvailability() }
        .onChange(of: draft.isSubmitting) { _, submitting in
            updateAvailability()
            if submitting { agentPickerFocused = false }
        }
        .task(id: catalogOwner) { await loadCatalog() }
    }

    private var introduction: some View {
        VStack(spacing: 10) {
            LogoMark(size: 36)
                .frame(width: 52, height: 46)
                .accessibilityHidden(true)
            Text(L10n.text("common.new_chat.title"))
                .font(Theme.font(24, weight: .medium))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(requiresHostSelection ? L10n.text("common.new_chat.choose_host") :
                 needsRepository ? L10n.text("common.new_chat.empty") : L10n.text("common.new_chat.subtitle"))
                .font(Theme.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The blocking choice, first. It used to sit under the agent and
            // autonomy controls, smallest of the three, which put the one
            // thing a send cannot happen without at the bottom of the card.
            HStack(spacing: 10) {
                if let hostPicker { hostPicker }
                if !requiresHostSelection { repositoryPicker.frame(maxWidth: .infinity, alignment: .leading) }
                Spacer(minLength: 0)
                if catalogLoading { ProgressView().controlSize(.small) }
                if catalogError != nil {
                    Button(L10n.text("common.retry"), systemImage: "arrow.clockwise") { Task { await loadCatalog() } }
                        .font(Theme.caption).disabled(catalogLoading)
                }
            }
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
        }
        .chatStartCard()
        .disabled(draft.isSubmitting)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A client picks its computer here too. Another one may already
            // have repositories, so the choice stays on the page.
            if let hostPicker { HStack { hostPicker; Spacer(minLength: 0) } }
            ChatStartOnboarding(onAdd: onAdd, acceptsFolderDrops: onAddFolders != nil, dropTargeted: folderDropTargeted)
        }
        .chatStartCard(highlighted: folderDropTargeted)
        .scaleEffect(folderDropTargeted && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: folderDropTargeted)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    /// Opens on the repository used last, from this launch or an earlier
    /// one, once it is in the list. With exactly one repository there is
    /// nothing to choose, so the page chooses it. Several and none
    /// remembered still asks. An unavailable remembered repository waits for
    /// discovery or an explicit choice. A choice already made is never replaced.
    private func chooseDefaultRepository() {
        draft.chooseDefaultRepository(available: repositories.map(\.id), isLoading: repositoriesLoading)
    }

    private func synchronizeComposer() {
        let peer = selected.map { WorkDestinationResolver.route(folderID: $0.id).peer } ?? nil
        model.configureLanding(draft, backends: backends, peer: peer)
        updateAvailability()
    }

    private func updateAvailability() {
        model.landingCanSubmit = allowsSend && selected != nil && backend != nil && !catalogLoading
        model.landingBlockReason = blockReason
    }

    /// What Send says while it cannot be pressed. A disabled control that
    /// names the missing piece teaches the requirement; one that is absent
    /// leaves a first-time reader with nothing to aim at.
    private var blockReason: String? {
        if draft.isSubmitting { return nil }
        if requiresHostSelection { return L10n.text("common.new_chat.choose_host") }
        if selected == nil { return L10n.text("common.new_chat.needs_repository") }
        if catalogLoading { return L10n.text("common.new_chat.finding_agents") }
        if backend == nil { return L10n.text("common.new_chat.needs_agent") }
        if !allowsSend { return L10n.text("common.new_chat.send_unavailable") }
        return nil
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

    /// One idiom for every control in the card: the same chrome, font and
    /// padding as the agent field and the mode pills beside it. It used to be
    /// a taller menu in its own shape, which made three controls read as
    /// three unrelated widgets.
    private var repositoryPicker: some View {
        Menu {
            if repositories.contains(where: { !$0.isRemote }) {
                Section(L10n.text("apple.rootview.this_computer.058bf37c")) {
                    ForEach(repositories.filter { !$0.isRemote }) { repository in
                        repositoryChoice(repository)
                    }
                }
            }
            ForEach(remoteMachines, id: \.id) { machine in
                Section {
                    ForEach(repositories.filter { $0.isRemote && ($0.machineID ?? $0.machineLabel ?? $0.id) == machine.id }) { repository in
                        repositoryChoice(repository)
                    }
                } header: {
                    Label(machine.name, systemImage: "globe")
                }
            }
            Divider()
            Button(L10n.text("common.new_chat.add_repository"), systemImage: "folder.badge.plus", action: onAdd)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected?.isRemote == true ? "globe" : "folder")
                    .font(Theme.fixed(11, weight: .medium))
                    .foregroundStyle(selected == nil ? Theme.accent : Color.secondary)
                Text(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1).truncationMode(selected == nil ? .tail : .middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.fixed(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
            .chatControlChrome(cornerRadius: 10)
            .overlay {
                // Lit until the choice is made. Nothing else on the page is.
                if selected == nil {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(L10n.text("common.new_chat.repository"))
        .accessibilityValue(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
    }

    private func repositoryChoice(_ repository: WorkspaceFolder) -> some View {
        Button { draft.repositoryID = repository.id } label: {
            Label(repository.name, systemImage: repository.id == draft.repositoryID ? "checkmark" : "folder")
        }
        .help(repository.path)
    }
}

/// A folder dropped on the first-run page becomes a repository. Only
/// directories count: a file has nowhere to go until there is a
/// conversation to attach it to.
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let add: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                guard !folders.isEmpty else { return false }
                add(folders)
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content.onAppear { isTargeted = false }
        }
    }
}
