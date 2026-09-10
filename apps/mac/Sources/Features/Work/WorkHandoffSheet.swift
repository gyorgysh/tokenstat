// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WorkHandoffSheet: View {
    @Bindable var chat: ChatModel
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var connection: WorkHandoffConnection?
    @State private var model: WorkHandoffModel?
    @State private var includeDraft = false
    @State private var files: [ChatAttachment] = []
    @State private var fileGeneration = UUID()
    @State private var loadingFiles = false
    @State private var importing = false
    @State private var preparingDraft = false
    @State private var notice: String?
    @State private var fileError: String?

    var body: some View {
        ThemedSheet(title: "Continue on another device",
            subtitle: chat.selected?.title ?? "This conversation", icon: .device,
            scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Pick up this conversation on another device while the computer that holds it is awake and connected.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if let model {
                    content(model)
                } else {
                    Text("Open the live conversation to share this work.")
                        .font(Theme.callout)
                }
                if let notice {
                    Text(notice).font(Theme.callout).foregroundStyle(Theme.accent)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                sharingHelp
            }
        }
        .modalFrame(width: 560, height: 660)
        .presentationBackground(Theme.background)
        .task {
            guard model == nil else { return }
            let peer = chat.peer
            guard let connection = WorkHandoffConnection(chat: chat, hostIsLinked: {
                account.account?.signedIn == true
                    && account.account?.machines.contains(where: { $0.publicIdentity == peer }) == true
            }) else { return }
            self.connection = connection
            let model = connection.makeModel()
            self.model = model
            await model.load()
        }
        .task(id: model?.shared?.requestID) { await loadFiles() }
        .onChange(of: chat.readingIdentity.reference) { _, _ in
            if connection?.isCurrent != true { model?.invalidate() }
        }
        .onChange(of: chat.selectionGeneration) { _, _ in
            if connection?.isCurrent != true { model?.invalidate() }
        }
        .onChange(of: account.account?.machines.compactMap(\.publicIdentity)) { _, _ in
            if connection?.isCurrent != true { model?.invalidate() }
        }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in
            if connection?.isCurrent != true { model?.invalidate() }
        }
        .onDisappear { model?.invalidate() }
    }

    private var sharingHelp: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ModalInfoRow(icon: .device, title: "Kept on the conversation’s computer",
                    text: "Your other devices ask that computer for shared work. It needs to be awake, connected, and allowing workspace access.")
                ModalInfoRow(icon: .edit, title: "Your draft is yours",
                    text: "Sharing a place does not include your words unless you select Include my unsent draft. Later edits stay on this device until you share again. Sharing never sends a message to an agent.")
                ModalInfoRow(icon: .history, title: "Choose where to continue",
                    text: "Use this opens the shared draft. Continue reading moves to the shared reading position. Neither happens automatically when shared work arrives.")
                ModalInfoRow(icon: .connect, title: "When the computer is unavailable",
                    text: "You can keep working with drafts and saved conversations already on this device. Shared words you have not opened here cannot be fetched until the computer is reachable again.")
            }
            .padding(.top, Theme.Space.m)
        } label: {
            ActionIcon.help.label("How sharing works")
                .font(Theme.callout.weight(.medium))
        }
    }

    @ViewBuilder private func content(_ model: WorkHandoffModel) -> some View {
        if model.phase == .invalidated {
            Text("This conversation changed. Close this sheet and open it again to continue.")
                .font(Theme.callout)
        } else {
            if preparingDraft { ProgressView("Preparing draft files…") }
            if model.isBusy { ProgressView(model.phase == .loading ? "Checking shared work…" : "Sharing…") }
            if let error = model.error {
                Text(error).font(Theme.callout).foregroundStyle(Theme.warning)
                Button("Try again", .refresh) {
                    Task { if model.canRetryShare { await model.retryShare() } else { await model.load() } }
                }.buttonStyle(SecondaryButtonStyle())
            }
            if model.phase == .conflict {
                Text("Another device shared work while you were sharing. Both versions are here.")
                    .font(Theme.callout).foregroundStyle(Theme.warning)
            }
            if let shared = model.shared {
                sharedCard(shared, model: model)
            }
            if model.phase == .conflict {
                if let draft = model.pending?.draft, draft != chat.handoffDraft {
                    draftCard(title: "Your version", draft: draft, attachments: chat.attachments)
                }
                Button("Keep mine", .done) { model.keepMine(); notice = "Your draft is unchanged on this device." }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Share my version", .upload) { Task { await model.shareMyVersion() } }
                    .buttonStyle(AccentButtonStyle())
            } else if model.phase == .shared {
                ModalInfoRow(icon: .done, title: "Ready on your other devices",
                    text: "Open this conversation there and choose Continue. Your draft stays here too.")
            } else if model.canShare {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("From this device").font(Theme.callout.weight(.semibold))
                    if !chat.draft.isEmpty || !chat.attachments.isEmpty {
                        Toggle("Include my unsent draft", isOn: $includeDraft).toggleStyle(.brandCheckbox)
                        if includeDraft {
                            draftCard(title: "Your draft", draft: chat.handoffDraft, attachments: chat.attachments)
                        }
                    }
                    Button("Share this place", .upload) { share(model) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(preparingDraft || chat.stagingAttachments > 0 || chat.sending || chat.unconfirmedSend != nil)
                }
            }
        }
    }

    private func sharedCard(_ shared: WorkHandoff, model: WorkHandoffModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Continue from \(shared.deviceName)").font(Theme.title3.weight(.semibold))
            Text("Shared \(Date(timeIntervalSince1970: Double(shared.updatedAtMs) / 1000).formatted(date: .abbreviated, time: .shortened))")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            if let draft = shared.draft {
                draftCard(title: "Shared draft", draft: draft, attachments: files)
                if loadingFiles { ProgressView("Checking shared files…") }
                if let fileError {
                    Text(fileError).font(Theme.caption).foregroundStyle(Theme.warning)
                    Button("Check files again", .refresh) { Task { await loadFiles() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !chat.draft.isEmpty || !chat.attachments.isEmpty {
                    draftCard(title: "On this device", draft: chat.handoffDraft, attachments: chat.attachments)
                    Text("Use this replaces the draft on this device. Copy keeps both versions where they are.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                Button(importing ? "Opening draft…" : "Use this", .restore) {
                    importDraft(draft, model: model)
                }.buttonStyle(AccentButtonStyle())
                    .disabled(loadingFiles || importing || fileError != nil || model.isBusy
                        || model.canRetryShare || chat.sending || chat.unconfirmedSend != nil)
                Button("Copy shared text", .copy) { copy(draft.text); notice = "Shared text copied." }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let anchor = shared.anchor {
                Button("Continue reading", .history) {
                    importAnchor(anchor, model: model)
                }.buttonStyle(SecondaryButtonStyle())
                    .disabled(importing || model.isBusy || model.canRetryShare)
            }
        }
    }

    private func draftCard(title: String, draft: WorkSharedDraft, attachments: [ChatAttachment]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.controlGlyph)
            if !draft.text.isEmpty { Text(draft.text).font(Theme.callout).textSelection(.enabled) }
            ForEach(attachments.filter { draft.attachmentIDs.contains($0.id) }) { file in
                Label(file.name, systemImage: ActionIcon.attach.symbol).font(Theme.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func share(_ model: WorkHandoffModel) {
        guard !preparingDraft, connection?.isCurrent == true else { return }
        chat.saveDraftNow()
        let draft = includeDraft ? chat.handoffDraft : nil
        let anchor: WorkHandoffAnchor?
        if let mark = ChatReadingStore.shared.mark(for: model.reference) {
            anchor = WorkHandoffAnchor(eventID: mark.eventID,
                fraction: UInt16(min(max(mark.within, 0), 1) * 10_000), followsLatest: false)
        } else if let last = chat.displayItems.last(where: { ChatReadingMark.isStable(eventID: $0.id) }) {
            anchor = WorkHandoffAnchor(eventID: last.id, fraction: 0, followsLatest: true)
        } else { anchor = nil }
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = ClientDeviceName.marketing
        #endif
        preparingDraft = true
        Task {
            defer { preparingDraft = false }
            do {
                let prepared: WorkSharedDraft?
                if let draft { prepared = try await chat.prepareHandoffDraft(draft) }
                else { prepared = nil }
                guard connection?.isCurrent == true else { return }
                await model.share(deviceName: name, draft: prepared, anchor: anchor)
            } catch { notice = error.localizedDescription }
        }
    }

    private func loadFiles() async {
        guard let connection, let record = model?.shared, let draft = record.draft else { files = []; return }
        let token = UUID()
        fileGeneration = token
        files = []
        fileError = nil
        loadingFiles = true
        defer { if fileGeneration == token { loadingFiles = false } }
        do {
            let result = try await connection.attachments(for: draft)
            guard fileGeneration == token, model?.phase != .invalidated, model?.shared == record, connection.isCurrent else { return }
            files = result
        } catch {
            guard fileGeneration == token, model?.phase != .invalidated, model?.shared == record, connection.isCurrent else { return }
            fileError = error.localizedDescription
        }
    }

    private func importDraft(_ draft: WorkSharedDraft, model: WorkHandoffModel) {
        guard !importing, let connection, connection.isCurrent else { return }
        let expected = chat.handoffDraft
        importing = true
        Task {
            defer { importing = false }
            do {
                let resolved = try await connection.attachments(for: draft)
                try await chat.keepImportedDraftFiles(resolved, reference: model.reference, expected: expected)
                guard model.phase != .invalidated, connection.isCurrent,
                      chat.importHandoffDraft(draft, files: resolved, replacing: expected, reference: model.reference) else {
                    notice = "Your draft changed while opening shared work. Review it and choose again."
                    return
                }
                dismiss()
            } catch { notice = error.localizedDescription }
        }
    }

    private func importAnchor(_ anchor: WorkHandoffAnchor, model: WorkHandoffModel) {
        guard !importing, let connection, connection.isCurrent else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                try await connection.verifyForImport()
                guard model.phase != .invalidated, connection.isCurrent,
                      chat.importHandoffAnchor(anchor, reference: model.reference) else { return }
                dismiss()
            } catch { notice = error.localizedDescription }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
