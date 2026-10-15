// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The same quiet starting surface on desktop and mobile. Repository choice
/// is local state; only Send or Open chat may create a conversation.
struct ChatStartPage: View {
    @Bindable var draft: ChatStartDraft
    let repositories: [WorkspaceFolder]
    var hostPicker: AnyView? = nil
    var allowsSend = true
    let onAdd: () -> Void
    let onSend: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @State private var backends: [ChatBackend] = []
    @State private var catalogLoading = false
    @State private var catalogError: String?
    @State private var catalogLease = UUID()
    private struct CatalogOwner: Equatable {
        var owner: ChatStartDraft.Owner?
        var repository: String?
    }
    private var catalogOwner: CatalogOwner { CatalogOwner(owner: draft.owner, repository: selected?.id) }
    private var backend: ChatBackend? { backends.first { $0.id == draft.agent?.backend } }
    private var selected: WorkspaceFolder? { repositories.first { $0.id == draft.repositoryID } }

    var body: some View {
        ZStack {
            Theme.background
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || scenePhase != .active)) { context in
                let phase = reduceMotion ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 12)
                Ellipse().fill(Theme.accent.opacity(0.09))
                    .frame(width: 620, height: 330)
                    .blur(radius: 85)
                    .offset(x: phase * 36, y: -90)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkle").font(Theme.font(29, weight: .light)).foregroundStyle(Theme.accent)
                        Text(L10n.text("common.new_chat.title"))
                            .font(Theme.font(34, weight: .semibold)).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.text("common.new_chat.subtitle"))
                            .font(Theme.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
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
                .padding(.horizontal, 24).padding(.vertical, 70)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: catalogOwner) { await loadCatalog() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text(L10n.text("common.new_chat.prompt")).font(Theme.chatBody).foregroundStyle(.secondary)
                        .padding(.top, 9).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $draft.text)
                    .font(Theme.chatBody).scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 190)
                    .focused($focused)
                    .accessibilityLabel(L10n.text("common.new_chat.prompt"))
            }
            agentPicker
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if let hostPicker { hostPicker }
                    repositoryPicker
                }
                Spacer(minLength: 0)
                Button(action: onSend) {
                    HStack(spacing: 7) {
                        if draft.isSubmitting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up") }
                        Text(draft.isSubmitting ? L10n.text("common.new_chat.preparing")
                             : draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? L10n.text("common.new_chat.open_chat") : L10n.text("common.new_chat.send"))
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!allowsSend || draft.isSubmitting || selected == nil || backend == nil || catalogLoading)
            }
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border))
        .shadow(color: Theme.accent.opacity(0.06), radius: 35, y: 12)
        .disabled(draft.isSubmitting)
    }

    private var agentPicker: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(backends.filter { $0.id != "sh" }) { choice in
                    Button {
                        draft.agent = .init(backend: choice.id, model: nil, effort: nil)
                    } label: {
                        Label(choice.label, systemImage: choice.id == draft.agent?.backend ? "checkmark" : "sparkle")
                    }
                    .disabled(choice.installed == false)
                }
            } label: {
                Label(backend?.label ?? L10n.text("apple.clientchatview.agent.11b39c93"), systemImage: "sparkle")
                    .font(Theme.caption).frame(minHeight: 32).contentShape(Rectangle())
            }
            .disabled(backends.isEmpty || catalogLoading)
            .accessibilityLabel(L10n.text("apple.clientchatview.agent.11b39c93"))
            if let backend {
                Menu {
                    Button(L10n.text("apple.chatsetupheader.default.21b111cb"), systemImage: "slider.horizontal.3") {
                        draft.agent?.model = nil
                    }
                    ForEach(backend.models, id: \.self) { model in
                        Button(model, systemImage: model == draft.agent?.model ? "checkmark" : "cpu") {
                            draft.agent?.model = model
                        }
                    }
                } label: {
                    Label(draft.agent?.model ?? L10n.text("apple.chatsetupheader.default.21b111cb"), systemImage: "cpu")
                        .font(Theme.caption).lineLimit(1).frame(minHeight: 32).contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.text("apple.chatsetupheader.model.5e2c614c"))
            }
            if catalogLoading { ProgressView().controlSize(.small) }
            if catalogError != nil {
                Button(L10n.text("common.retry"), systemImage: "arrow.clockwise") { Task { await loadCatalog() } }
                    .font(Theme.caption).disabled(catalogLoading)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func loadCatalog() async {
        let requested = catalogOwner
        let lease = UUID()
        catalogLease = lease
        catalogLoading = false
        backends = []
        catalogError = nil
        guard let owner = requested.owner, let repository = requested.repository else {
            draft.agent = nil
            return
        }
        catalogLoading = true
        defer { if catalogLease == lease { catalogLoading = false } }
        let peer = WorkDestinationResolver.route(folderID: repository).peer
        do {
            let available = try await Bridge.chatBackends(peer: peer)
            guard !Task.isCancelled, catalogLease == lease, catalogOwner == requested, WorkSessionContext.shared.scope == owner.scope,
                  WorkSessionContext.shared.generation == owner.session else { return }
            backends = available
            if let choice = draft.agent, let descriptor = available.first(where: { $0.id == choice.backend && $0.installed != false }) {
                if let model = choice.model, !descriptor.models.contains(model) { draft.agent?.model = nil }
                if let effort = choice.effort, !descriptor.efforts.contains(effort) { draft.agent?.effort = nil }
            } else { draft.agent = ChatModel.newChatDefaults(backends: available) }
            if draft.agent == nil {
                catalogError = L10n.text("apple.chatsetupheader.no_agents_installed_set_up_an_agent_to_sta.2f73b57f")
            }
        } catch {
            guard !Task.isCancelled, catalogLease == lease, catalogOwner == requested else { return }
            draft.agent = nil
            catalogError = error.localizedDescription
        }
    }

    private var repositoryPicker: some View {
        Menu {
            ForEach(repositories) { repository in
                Button {
                    draft.repositoryID = repository.id
                } label: {
                    Label(repository.machineLabel.map { "\(repository.name) · \($0)" } ?? repository.name,
                          systemImage: repository.id == draft.repositoryID ? "checkmark" : "folder")
                }
                .help(repository.path)
            }
            Button(L10n.text("common.new_chat.add_repository"), systemImage: "folder.badge.plus", action: onAdd)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(Theme.accent)
                Text(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(Theme.caption)
            }
            .font(Theme.callout).padding(.horizontal, 10).frame(minHeight: 44)
            .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .accessibilityLabel(L10n.text("common.new_chat.repository"))
        .accessibilityValue(selected?.name ?? L10n.text("common.new_chat.choose_repository"))
    }
}
