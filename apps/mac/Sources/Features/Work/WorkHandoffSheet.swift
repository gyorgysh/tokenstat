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
        ThemedSheet(title: L10n.text("apple.workhandoffsheet.continue_on_another_device.b5836f9a"),
            subtitle: chat.selected?.title ?? L10n.text("apple.workhandoffsheet.this_conversation.0e82ebfc"), icon: .device,
            scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(L10n.text("apple.workhandoffsheet.pick_up_this_conversation_on_another_devic.6f518069"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if let model {
                    content(model)
                } else {
                    Text(L10n.text("apple.workhandoffsheet.open_the_live_conversation_to_share_this_w.21af9551"))
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
                ModalInfoRow(icon: .device, title: L10n.text("apple.workhandoffsheet.kept_on_the_conversation_s_computer.296de7f7"),
                    text: L10n.text("apple.workhandoffsheet.your_other_devices_ask_that_computer_for_s.9c03f0b7"))
                ModalInfoRow(icon: .edit, title: L10n.text("apple.workhandoffsheet.your_draft_is_yours.289be195"),
                    text: L10n.text("apple.workhandoffsheet.sharing_a_place_does_not_include_your_word.ce606d91"))
                ModalInfoRow(icon: .history, title: L10n.text("apple.workhandoffsheet.choose_where_to_continue.3e822dbf"),
                    text: L10n.text("apple.workhandoffsheet.use_this_opens_the_shared_draft_continue_r.1005a580"))
                ModalInfoRow(icon: .connect, title: L10n.text("apple.workhandoffsheet.when_the_computer_is_unavailable.a944ec4d"),
                    text: L10n.text("apple.workhandoffsheet.you_can_keep_working_with_drafts_and_saved.d80c920f"))
            }
            .padding(.top, Theme.Space.m)
        } label: {
            ActionIcon.help.label(L10n.text("apple.workhandoffsheet.how_sharing_works.90f93832"))
                .font(Theme.callout.weight(.medium))
        }
    }

    @ViewBuilder private func content(_ model: WorkHandoffModel) -> some View {
        if model.phase == .invalidated {
            Text(L10n.text("apple.workhandoffsheet.this_conversation_changed_close_this_sheet.e11a2582"))
                .font(Theme.callout)
        } else {
            if preparingDraft { ProgressView(L10n.text("apple.workhandoffsheet.preparing_draft_files.3e0d0b2b")) }
            if model.isBusy { ProgressView(model.phase == .loading ? L10n.text("apple.workhandoffsheet.checking_shared_work.49ef87bb") : L10n.text("apple.workhandoffsheet.sharing.2e913af4")) }
            if let error = model.error {
                Text(error).font(Theme.callout).foregroundStyle(Theme.warning)
                Button(L10n.text("apple.workhandoffsheet.try_again.d8b8392e"), .refresh) {
                    Task { if model.canRetryShare { await model.retryShare() } else { await model.load() } }
                }.buttonStyle(SecondaryButtonStyle())
            }
            if model.phase == .conflict {
                Text(L10n.text("apple.workhandoffsheet.another_device_shared_work_while_you_were.e60d9e79"))
                    .font(Theme.callout).foregroundStyle(Theme.warning)
            }
            if let shared = model.shared {
                sharedCard(shared, model: model)
            }
            if model.phase == .conflict {
                if let draft = model.pending?.draft, draft != chat.handoffDraft {
                    draftCard(title: L10n.text("apple.workhandoffsheet.your_version.f06cf159"), draft: draft, attachments: chat.attachments)
                }
                Button(L10n.text("apple.workhandoffsheet.keep_mine.0335c833"), .done) { model.keepMine(); notice = L10n.text("apple.workhandoffsheet.your_draft_is_unchanged_on_this_device.44ba61a3") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(L10n.text("apple.workhandoffsheet.share_my_version.2888feac"), .upload) { Task { await model.shareMyVersion() } }
                    .buttonStyle(AccentButtonStyle())
            } else if model.phase == .shared {
                ModalInfoRow(icon: .done, title: L10n.text("apple.workhandoffsheet.ready_on_your_other_devices.af50c8dc"),
                    text: L10n.text("apple.workhandoffsheet.open_this_conversation_there_and_choose_co.c4f25c3e"))
            } else if model.canShare {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("apple.workhandoffsheet.from_this_device.37910fa8")).font(Theme.callout.weight(.semibold))
                    if !chat.draft.isEmpty || !chat.attachments.isEmpty {
                        Toggle(L10n.text("apple.workhandoffsheet.include_my_unsent_draft.1764aefe"), isOn: $includeDraft).toggleStyle(.brandCheckbox)
                        if includeDraft {
                            draftCard(title: L10n.text("apple.workhandoffsheet.your_draft.931ad336"), draft: chat.handoffDraft, attachments: chat.attachments)
                        }
                    }
                    Button(L10n.text("apple.workhandoffsheet.share_this_place.8d748a2d"), .upload) { share(model) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(preparingDraft || chat.stagingAttachments > 0 || chat.sending || chat.unconfirmedSend != nil)
                }
            }
        }
    }

    private func sharedCard(_ shared: WorkHandoff, model: WorkHandoffModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("apple.workhandoffsheet.continue_from_0.5f98842e", "\(shared.deviceName)")).font(Theme.title3.weight(.semibold))
            Text(L10n.text("apple.workhandoffsheet.shared_0.3bb181a7", "\(Date(timeIntervalSince1970: Double(shared.updatedAtMs) / 1000).formatted(date: .abbreviated, time: .shortened))"))
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            if let draft = shared.draft {
                draftCard(title: L10n.text("apple.workhandoffsheet.shared_draft.9f03d34e"), draft: draft, attachments: files)
                if loadingFiles { ProgressView(L10n.text("apple.workhandoffsheet.checking_shared_files.0a7a6940")) }
                if let fileError {
                    Text(fileError).font(Theme.caption).foregroundStyle(Theme.warning)
                    Button(L10n.text("apple.workhandoffsheet.check_files_again.ae8be3d2"), .refresh) { Task { await loadFiles() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !chat.draft.isEmpty || !chat.attachments.isEmpty {
                    draftCard(title: L10n.text("apple.workhandoffsheet.on_this_device.38b9d88c"), draft: chat.handoffDraft, attachments: chat.attachments)
                    Text(L10n.text("apple.workhandoffsheet.use_this_replaces_the_draft_on_this_device.1f377038"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                Button(importing ? L10n.text("apple.workhandoffsheet.opening_draft.34c32aa9") : L10n.text("apple.workhandoffsheet.use_this.b2919965"), .restore) {
                    importDraft(draft, model: model)
                }.buttonStyle(AccentButtonStyle())
                    .disabled(loadingFiles || importing || fileError != nil || model.isBusy
                        || model.canRetryShare || chat.sending || chat.unconfirmedSend != nil)
                Button(L10n.text("apple.workhandoffsheet.copy_shared_text.03b373fb"), .copy) { copy(draft.text); notice = L10n.text("apple.workhandoffsheet.shared_text_copied.358c6857") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let anchor = shared.anchor {
                Button(L10n.text("apple.workhandoffsheet.continue_reading.66e7853c"), .history) {
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
        let name = Host.current().localizedName ?? L10n.text("apple.workhandoffsheet.mac.8b3795aa")
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
                    notice = L10n.text("apple.workhandoffsheet.your_draft_changed_while_opening_shared_wo.ccca9699")
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
