// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Repository choice, writing and setup stay local until an explicit Send.
/// The ordinary chat composer edits an isolated in-memory model, so starting
/// a conversation offers the same attachment and agent controls as continuing
/// one.
///
/// The page is one lit object in a dark room. The repository is the only
/// choice that blocks a send, so it sits first inside the card rather than
/// last and least under it, and Send stays on screen while it is impossible
/// so the disabled state can say what is missing.
struct ChatStartPage: View {
    @Bindable var draft: ChatStartDraft
    let repositories: [WorkspaceFolder]
    var isFullScreen = false
    var titlebarDragHeight: CGFloat = 0
    var hostPicker: AnyView? = nil
    var allowsSend = true
    /// The repository list is still being read, so an empty one says nothing
    /// yet and the page must not offer first-run help on the strength of it.
    var repositoriesLoading = false
    let onAdd: () -> Void
    let onSend: () -> Void
    /// Adds dropped folders as repositories. Only offered where a folder can
    /// be dropped at all.
    var onAddFolders: (([URL]) -> Void)? = nil
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
    @State private var folderDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var motion = ChatStartSurfaceMotion()
    @State private var hovering = false
    @State private var agentPickerFocused = false
    /// Staged arrival, and the still-field countdown.
    @State private var revealed = false
    @State private var quiet = false
    @State private var activity = 0
    @State private var parallax = CGSize.zero
    private struct CatalogOwner: Equatable {
        var owner: ChatStartDraft.Owner?
        var repository: String?
    }
    private struct AdapterIdentity: Equatable {
        var owner: ChatStartDraft.Owner?
        var reference: WorkReference?
        var agent: ChatStartDraft.AgentChoice?
    }
    /// What the still-surface countdown restarts for.
    private struct Vigil: Equatable {
        var activity: Int
        var hovering: Bool
    }
    private var catalogOwner: CatalogOwner { CatalogOwner(owner: draft.owner, repository: selected?.id) }
    private var adapterIdentity: AdapterIdentity { .init(owner: draft.owner, reference: draft.attachmentReference, agent: draft.agent) }
    private var backend: ChatBackend? { backends.first { $0.id == draft.agent?.backend && $0.installed != false } }
    private var selected: WorkspaceFolder? { repositories.first { $0.id == draft.repositoryID } }
    private var writing: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Nothing to talk about yet. The page teaches the first steps instead
    /// of offering a composer that cannot send.
    private var needsRepository: Bool { repositories.isEmpty && !repositoriesLoading }
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
            ChatStartLiquidSurface(motion: motion, isFullScreen: isFullScreen, lift: writing || draft.isSubmitting,
                                   preparingSince: draft.isSubmitting ? draft.preparationStartedAt : nil,
                                   parallax: draft.isSubmitting ? .zero : parallax, revealed: revealed,
                                   hovering: hovering || draft.isSubmitting,
                                   active: active && !agentPickerFocused && scenePhase == .active && (!quiet || draft.isSubmitting),
                                   lit: active && !agentPickerFocused && scenePhase == .active)
            GeometryReader { pane in
                ScrollView {
                    VStack(spacing: 26) {
                        introduction
                        if needsRepository {
                            onboarding
                        } else {
                            composer
                            if showsStarters {
                                ChatStartStarters(onPick: { draft.text = $0 }, revealed: revealed)
                                    .padding(.top, -8)
                                    .transition(.opacity)
                            }
                        }
                        if let error = draft.error ?? catalogError {
                            Text(error).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 700)
                    .anchorPreference(key: ChatStartContentAnchor.self, value: .bounds) { $0 }
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    // Centred in the pane, then biased up by a few percent,
                    // because optical centre sits above geometric centre. The
                    // bias is padding rather than an offset so the exclusion
                    // anchor above still describes where the card really is.
                    .padding(.bottom, 48 + min(96, pane.size.height * 0.07))
                    .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .center)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsStarters)
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: needsRepository)
                // A phone bounces a scroll view whose content already fits,
                // which slid the card away from its own light.
                .scrollBounceBehavior(.basedOnSize)
                // The card's frame goes to the surface, which draws the
                // spectrum the glass throws. Plain state on the motion
                // object, like the pointer, so nothing redraws for it.
                .environment(\.chatStartCardFrame) { frame in motion.card = frame }
                .overlayPreferenceValue(ChatStartContentAnchor.self) { anchor in
                    if let anchor {
                        let excluded = pane[anchor].insetBy(dx: -12, dy: -12)
                        ChatStartEmptySpace(excluded: excluded, reservedTop: titlebarDragHeight,
                                            tap: displaceLiquid, hover: { moveLiquid(to: $0, in: pane.size) })
                            .allowsHitTesting(active && !agentPickerFocused)
                    }
                }
            }
            .coordinateSpace(name: ChatStartPaneSpace.name)
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
            // The overlay stops hit testing while the picker is up, so no
            // `.ended` hover ever arrives to say the pointer has gone.
            if focused { hovering = false }
            motion.settled = nil
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: draft.isSubmitting)
        .clipped()
        .chatDropSurface(enabled: acceptsDrops, isTargeted: $dropTargeted, receive: receive)
        .onAppear { active = true; synchronizeComposer(); revealed = true; chooseDefaultRepository() }
        .onChange(of: repositories.map(\.id)) { _, _ in chooseDefaultRepository() }
        .onChange(of: repositoriesLoading) { _, _ in chooseDefaultRepository() }
        .onChange(of: draft.owner) { _, _ in chooseDefaultRepository() }
        .onDisappear {
            active = false; catalogLease = UUID(); hovering = false
            motion.reset(); agentPickerFocused = false; parallax = .zero
        }
        // Nothing has happened for a while, so the field holds its last frame.
        // The light behind it keeps breathing on the compositor, which costs
        // nothing, and any impulse starts the clock again where it stopped.
        .task(id: Vigil(activity: activity, hovering: hovering)) {
            quiet = false
            // A pointer that has stopped moving stops bumping the count, so a
            // hand left resting on the page settles the surface as well.
            try? await Task.sleep(for: .seconds(hovering ? 6 : 3.2))
            guard !Task.isCancelled else { return }
            quiet = true
        }
        .onChange(of: adapterIdentity) { _, _ in synchronizeComposer() }
        .onChange(of: draft.text) { _, text in if model.draft != text { model.draft = text } }
        // Starting to write, or clearing the field, is worth one more look at
        // the folds under the brighter light. Then it settles again.
        .onChange(of: writing) { _, _ in activity &+= 1 }
        .onChange(of: draft.attachments) { _, _ in synchronizeComposer() }
        .onChange(of: allowsSend) { _, _ in updateAvailability() }
        .onChange(of: draft.isSubmitting) { _, submitting in
            updateAvailability()
            if submitting { agentPickerFocused = false; activity &+= 1 }
        }
        .task(id: catalogOwner) { await loadCatalog() }
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            LogoMark(size: 58)
                .frame(width: 92, height: 74)
                .accessibilityHidden(true)
            Text(L10n.text("common.new_chat.title"))
                .font(Theme.font(30, weight: .medium))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(needsRepository ? L10n.text("common.new_chat.empty") : L10n.text("common.new_chat.subtitle"))
                .font(Theme.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.10), value: revealed)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The blocking choice, first. It used to sit under the agent and
            // autonomy controls, smallest of the three, which put the one
            // thing a send cannot happen without at the bottom of the card.
            HStack(spacing: 10) {
                if let hostPicker { hostPicker }
                repositoryPicker
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
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed ? 1 : 0.985, anchor: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.12).delay(0.22), value: revealed)
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
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed ? 1 : 0.985, anchor: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.12).delay(0.22), value: revealed)
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

    /// A click drops a ring that travels out, bends the surface as it goes
    /// and leaves it flat behind. Three can be in the air at once.
    private func displaceLiquid(at point: CGPoint) {
        guard active, !agentPickerFocused, !reduceMotion, !dimFlashingLights, scenePhase == .active else { return }
        motion.strike(point, at: Date.timeIntervalSinceReferenceDate)
        activity &+= 1
    }

    /// The pointer wipes the condensation off the glass, drags what is
    /// under it along, and the room leans away from it.
    ///
    /// The first two are samples the shader reads straight out of a plain
    /// object, so following the mouse closely invalidates no view at all. The
    /// lean is the only published part, it moves once the pointer has really
    /// gone somewhere, and the compositor animates it. The page used to spray
    /// ripples here instead, which pinned it at 60 Hz for as long as the
    /// mouse moved and read as a toy rather than as depth.
    private func moveLiquid(to point: CGPoint?, in size: CGSize) {
        guard active, !agentPickerFocused, !reduceMotion, !dimFlashingLights, scenePhase == .active,
              let point, size.width > 0, size.height > 0 else {
            if hovering { hovering = false }
            motion.aim = .zero
            motion.settled = nil
            settle(nil)
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let sampled = motion.note(point, at: now)
        // The depth layers follow every move. They ease on their own clock
        // in the shader's arguments, so this is a plain write.
        motion.aim = CGSize(width: min(1, max(-1, (point.x - size.width / 2) / (size.width / 2))),
                            height: min(1, max(-1, (point.y - size.height / 2) / (size.height / 2))))
        if !hovering { hovering = true }
        // At most one state change a second, and only while the pointer is
        // really travelling: enough to hold the surface awake, far too rare
        // to be worth avoiding.
        if sampled, now - motion.lastWake >= 0.9 {
            motion.lastWake = now
            activity &+= 1
        }
        guard let previous = motion.settled else { motion.settled = point; return }
        guard hypot(point.x - previous.x, point.y - previous.y) >= 36 else { return }
        motion.settled = point
        let fromCentre = CGSize(width: (point.x - size.width / 2) / size.width,
                                height: (point.y - size.height / 2) / size.height)
        settle(CGSize(width: -fromCentre.width * 18, height: -fromCentre.height * 13))
    }

    private func settle(_ offset: CGSize?) {
        let resolved = offset ?? .zero
        guard resolved != parallax else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 1.3)) { parallax = resolved }
    }

    /// One idiom for every control in the card: the same chrome, font and
    /// padding as the agent field and the mode pills beside it. It used to be
    /// a taller menu in its own shape, which made three controls read as
    /// three unrelated widgets.
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
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(Theme.fixed(11, weight: .medium))
                    .foregroundStyle(selected == nil ? Theme.accent : Color.secondary)
                Text(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
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

/// Resolving the content anchor in this overlay avoids mixed window/local
/// coordinates. The even-odd hit shape contains only empty background: native
/// text fields, menus, popovers and the whole composer never receive this gesture.
private struct ChatStartContentAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct ChatStartEmptyShape: Shape {
    let excluded: CGRect
    let reservedTop: CGFloat
    func path(in rect: CGRect) -> Path {
        let available = CGRect(x: rect.minX, y: rect.minY + reservedTop,
                               width: rect.width, height: max(0, rect.height - reservedTop))
        var path = Path(available)
        let hole = excluded.intersection(available)
        if !hole.isNull { path.addRect(hole) }
        return path
    }
}

private struct ChatStartEmptySpace: View {
    let excluded: CGRect
    let reservedTop: CGFloat
    let tap: (CGPoint) -> Void
    let hover: (CGPoint?) -> Void
    var body: some View {
        Color.clear
            .contentShape(ChatStartEmptyShape(excluded: excluded, reservedTop: reservedTop), eoFill: true)
            .onTapGesture(coordinateSpace: .local) { point in
                guard point.y >= reservedTop, !excluded.contains(point) else { return }
                tap(point)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover(point.y < reservedTop || excluded.contains(point) ? nil : point)
                case .ended: hover(nil)
                }
            }
            .accessibilityHidden(true)
    }
}

/// One light behind the composer, and the surface in front of it.
///
/// Three layers. Underneath is the floor: the Mac's own window glass, which
/// has a desktop behind it, or on a phone and an iPad an opaque colour, since
/// a full-screen page has nothing behind it for a material to pull through.
/// The light is an elliptical gradient the compositor owns, so its twenty
/// second breath and its lean after the pointer never cost a frame. The
/// surface on top is `ChatStartField.metal`, evaluated per pixel on the GPU,
/// which is what affords the condensation, the rings and the dispersion that
/// the old CPU raster could not have drawn at 72 pixels across.
///
/// It still stops. A few seconds after the last thing happened the timeline
/// pauses and the surface holds its frame, because a full-window shader is
/// cheap but a laptop running one forever is not.
private struct ChatStartLiquidSurface: View {
    let motion: ChatStartSurfaceMotion
    let isFullScreen: Bool
    let lift: Bool
    let preparingSince: Double?
    let parallax: CGSize
    let revealed: Bool
    /// The pointer is on the page, so the surface is worth a full frame rate.
    let hovering: Bool
    /// The surface is being drawn.
    let active: Bool
    /// The page is on screen, so the light is up even while the surface rests.
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var elapsed = 0.0
    @State private var clockStarted: Double?
    @State private var breathing = false

    private var animates: Bool { active && !reduceMotion && !dimFlashingLights }

    var body: some View {
        ZStack {
            glass
            keyLight
            if !reduceTransparency {
                TimelineView(.animation(minimumInterval: hovering ? 1 / 60 : 1 / 24, paused: !animates)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let time = elapsed + (clockStarted.map { max(0, now - $0) } ?? 0)
                    GeometryReader { pane in
                        // Not a black fill: a shader that fails to resolve
                        // leaves the layer as it was drawn, and the page is
                        // the one place that would be a solid slab.
                        Rectangle()
                            .fill(ChatStartGlassField.ground)
                            .colorEffect(ChatStartGlassField.shader(
                                size: pane.size, time: time, now: now, motion: motion,
                                lift: lift ? 1 : 0,
                                gathering: preparingSince.map { animates ? max(0.001, now - $0) : 0 } ?? 0,
                                palette: .init(accent: Theme.accent, secondary: Theme.secondary,
                                               background: ChatStartGlassField.ground, dark: colorScheme == .dark)))
                    }
                    // No parallax here, deliberately. The light is the deep
                    // layer and leans; the surface is at the glass and holds
                    // still. Offsetting it too would draw the wipe up to
                    // eighteen points from the pointer that made it.
                }
                .opacity(revealed ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: revealed)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear {
            if animates { clockStarted = Date.timeIntervalSinceReferenceDate }
            breathing = true
        }
        .onChange(of: animates) { _, running in
            let now = Date.timeIntervalSinceReferenceDate
            if let started = clockStarted { elapsed += max(0, now - started) }
            clockStarted = running ? now : nil
        }
    }

    /// Accent at the centre, nothing at the corners. Drawn once and animated
    /// by the compositor, so neither the breath nor the lean costs a frame.
    @ViewBuilder private var keyLight: some View {
        if !reduceTransparency {
            EllipticalGradient(
                stops: [
                    .init(color: Theme.accent.opacity((colorScheme == .dark ? 0.20 : 0.10) * ChatStartGlassField.lightGain), location: 0),
                    .init(color: Theme.accent.opacity((colorScheme == .dark ? 0.065 : 0.035) * ChatStartGlassField.lightGain), location: 0.48),
                    .init(color: .clear, location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 0.46),
                startRadiusFraction: 0,
                endRadiusFraction: 0.60
            )
            .opacity(brightness)
            .animation(reduceMotion || dimFlashingLights ? nil : .easeInOut(duration: 10).repeatForever(autoreverses: true),
                       value: breathing)
            .offset(parallax)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: lift)
            // The light blooms before anything is written on it.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: revealed)
        }
    }

    private var brightness: Double {
        guard lit, revealed else { return 0 }
        let breath = breathing ? 1.0 : 0.90
        return breath * (lift ? 1.14 : 1)
    }

    @ViewBuilder private var glass: some View {
        if reduceTransparency { ChatStartGlassField.ground }
        else {
            #if os(macOS)
            if #available(macOS 26, *) {
                SidebarGlassSurface(isFullScreen: isFullScreen, cornerRadius: 0)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
            #else
            // Nothing behind this page on a phone or an iPad, so there is
            // nothing for a material to pull through: it frosted a blank and
            // read pale against the app. An opaque floor instead, with the
            // light, the folds and the rings all drawn on top of it.
            ChatStartGlassField.ground
            #endif
        }
    }
}
