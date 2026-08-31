// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
    let workspaceID: String
    var workspaceName: String? = nil
    @State private var draft = ""
    @State private var draftSelection = NSRange(location: 0, length: 0)
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var settleMood: PersonaMood?
    @State private var paneDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(scope: workspaceName.map { ScopeChip(label: $0, symbol: "folder.fill") }) {
                ToolbarIconButton(systemImage: "plus", help: "New chat") {
                    Task { await model.create() }
                }
            }
            #endif
            if let chat = model.selected {
                transcript(chat)
                    .overlay {
                        if dropExperienceVisible {
                            dropExperience
                        }
                    }
                // A blocked turn takes the composer's place rather than
                // sitting beside it. There is nothing useful to type while an
                // agent is parked, and removing the field is the plainest way
                // to say what the conversation is actually waiting for.
                if model.approvals.isEmpty {
                    ChatComposer(
                        model: model,
                        chat: chat,
                        draft: $draft,
                        selection: $draftSelection,
                        attachments: model.attachments,
                        previews: model.attachmentPreviews,
                        running: model.busy,
                        placeholder: "Ask about \(workspaceName ?? "this folder")",
                        onSend: { submit(from: chat) },
                        onStop: { Task { await model.stop() } },
                        onAttach: { item in await model.attach(item) },
                        onRemove: { model.removeAttachment($0) },
                        onDropProviders: { providers in
                            Task { await receive(providers) }
                        },
                        onDropTargeted: { composerDropTargeted = $0 }
                    )
                } else {
                    ChatApprovalBar(
                        approvals: model.approvals,
                        resolve: { approval, choice in
                            Task { await model.resolve(approval, choice: choice) }
                        },
                        showInTranscript: { approval in
                            scrollTarget = "approval-\(approval.id)"
                        }
                    )
                }
            } else {
                empty
                    .overlay {
                        if dropExperienceVisible {
                            dropExperience
                        }
                    }
            }
        }
        .background(Theme.background)
        .onDrop(of: ChatInbox.dropTypes, isTargeted: $paneDropTargeted) { providers in
            Task { await receive(providers) }
            return true
        }
        .overlay(alignment: .topTrailing) {
            TransientToast(message: $dropNotice, severity: .warning)
                .padding(.top, Theme.Space.m)
                .padding(.trailing, Theme.Space.m)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropExperienceVisible)
        #if os(macOS)
        .onExitCommand {
            if model.busy { Task { await model.stop() } }
        }
        #endif
        #if !os(macOS)
        .navigationTitle(model.selected?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", .create) { Task { await model.create() } }
            }
        }
        #endif
        .task(id: workspaceID) { await model.load(workspaceID: workspaceID) }
        .task(id: model.selected?.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await model.poll()
            }
        }
        .alert("Chat unavailable", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func transcript(_ chat: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    #if !os(macOS)
                    if !model.chats.isEmpty {
                        conversationMenu
                    }
                    #endif
                    if model.displayItems.isEmpty, !chat.running {
                        emptyConversation
                    }
                    ForEach(model.displayItems) { item in
                        ChatEventRow(
                            item: item,
                            defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                            agentLabel: { backend in
                                model.backend(for: backend)?.label ?? backend.capitalized
                            },
                            attachmentData: attachmentData(for: item),
                            attachmentRevision: model.responseAttachmentRevision,
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            },
                            faceSeed: model.faceSeed
                        )
                    }
                    if let mood = liveMood {
                        ChatWorkingIndicator(seed: model.faceSeed, mood: mood)
                    }
                    TranscriptBottomSentinel()
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.vertical, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
                .chatScrollContent()
            }
            .chatScrollViewport()
            .overlay(alignment: .bottom) {
                if follow.showJump && model.approvals.isEmpty {
                    JumpToLatestButton {
                        follow.jump()
                        pinToLatest(proxy, animated: true)
                    }
                }
            }
            .onPreferenceChange(ChatScrollContentKey.self) { frame in
                follow.noteContent(frame)
            }
            .onPreferenceChange(ChatScrollViewportKey.self) { height in
                follow.noteViewport(height: height)
            }
            .onChange(of: structureToken) { _, _ in
                pinToLatest(proxy, animated: true)
            }
            .onChange(of: streamToken) { _, _ in
                pinToLatest(proxy, animated: false)
            }
            .onChange(of: chat.running) { _, _ in
                pinToLatest(proxy, animated: true)
            }
            .onChange(of: model.busy) { was, now in
                settleAfterTurn(was: was, now: now)
            }
            .onChange(of: model.approvals.isEmpty) { _, empty in
                follow.suppressed = !empty
            }
            // A request that arrives while a reply is still streaming would
            // otherwise be pushed off the top of the page before anyone saw
            // it. Bring the card to them.
            .onChange(of: model.approvals.first?.id) { _, id in
                guard let id else { return }
                scrollTo("approval-\(id)", proxy, animated: true)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                scrollTo(target, proxy, animated: true)
                scrollTarget = nil
            }
            .onAppear {
                follow.suppressed = !model.approvals.isEmpty
                pinToLatest(proxy, animated: false)
            }
            .task(id: settleMood) {
                guard settleMood == .ok else { return }
                try? await Task.sleep(for: .milliseconds(480))
                settleMood = nil
            }
        }
    }

    private func attachmentData(for item: ChatDisplayItem) -> Data? {
        guard case let .attachment(attachment) = item.kind else { return nil }
        return model.responseAttachmentData[attachment.id]
    }

    #if !os(macOS)
    private var conversationMenu: some View {
        Menu(model.selected?.title ?? "Chat") {
            ForEach(model.chats) { conversation in
                Button(conversation.title) { Task { await model.select(conversation) } }
            }
        }
    }
    #endif

    private var liveMood: PersonaMood? {
        if let settleMood { return settleMood }
        if !model.approvals.isEmpty { return .waiting }
        guard model.busy else { return nil }
        return model.isRunningTool ? .working : .thinking
    }

    private var structureToken: String {
        TranscriptFollow.structureToken(
            items: model.displayItems,
            busy: model.busy,
            runningTool: model.isRunningTool,
            settle: settleMood
        )
    }

    private var streamToken: Int {
        TranscriptFollow.streamExtent(model.displayItems)
    }

    private func settleAfterTurn(was: Bool, now: Bool) {
        if now {
            settleMood = nil
            return
        }
        guard was else { return }
        if case .failed = model.displayItems.last?.kind {
            settleMood = nil
        } else {
            settleMood = .ok
        }
    }

    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // A pending request owns the view. Streaming text must not scroll it
        // back out from under somebody who is reading it to decide.
        guard follow.pinned, model.approvals.isEmpty else { return }
        scrollTo(TranscriptFollow.bottomID, proxy, animated: animated)
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy, animated: Bool) {
        if !animated || reduceMotion {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: TranscriptFollow.structureDuration)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvals.contains { $0.id == approval.id }
        }
        return false
    }

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busy else { return }
        draft = ""
        Task { await model.send(text) }
    }

    private var dropExperienceVisible: Bool {
        paneDropTargeted || composerDropTargeted
    }

    private var dropExperience: some View {
        ChatDropExperience(seed: model.faceSeed)
    }

    private func receive(_ providers: [NSItemProvider]) async {
        await receive(ChatInbox.drops(from: providers))
    }

    private func receive(_ drops: [ChatInboxDrop]) async {
        guard !drops.isEmpty else { return }
        if model.selected == nil {
            await model.create()
        }
        for drop in drops {
            switch drop {
            case let .attachment(item):
                await model.attach(item)
            case let .text(text):
                insertInDraft(text)
            case .folder:
                showDropNotice("Attach files, not folders")
            }
        }
    }

    private func insertInDraft(_ text: String) {
        let current = draft as NSString
        let location = min(max(0, draftSelection.location), current.length)
        let length = min(max(0, draftSelection.length), current.length - location)
        draft = current.replacingCharacters(in: NSRange(location: location, length: length), with: text)
        draftSelection = NSRange(location: location + (text as NSString).length, length: 0)
    }

    private func showDropNotice(_ message: String) {
        dropNoticeGeneration += 1
        let generation = dropNoticeGeneration
        dropNotice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard dropNoticeGeneration == generation else { return }
            dropNotice = nil
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: Theme.Space.m) {
            ChatScene(reduceMotion: reduceMotion)
            Text("Ask about \(workspaceName ?? "this folder")")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.m)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            ChatScene(reduceMotion: reduceMotion)
            Text("Start a chat")
                .font(Theme.title2.weight(.semibold))
            Text("Ask an agent to explore, plan, or work in this folder.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("New chat", .create) {
                Task { await model.create() }
            }
            .buttonStyle(AccentButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.l)
    }
}

/// One themed promise for every chat drop target, from a wide Mac transcript
/// to an empty iPad conversation.
struct ChatDropExperience: View {
    var seed: UInt64

    var body: some View {
        ZStack {
            Theme.accentSoft.opacity(0.58)
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.82), lineWidth: 1.5)
                .padding(8)
            VStack(spacing: Theme.Space.s) {
                PersonaMark(seed: seed, size: 58, state: .waiting)
                Text("Drop to attach")
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("Files attach. Text and links join your message.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: Theme.shadow(0.18), radius: 18, y: 8)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}
