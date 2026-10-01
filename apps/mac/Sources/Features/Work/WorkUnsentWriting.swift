// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WorkUnsentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct WorkSignOutReview: View {
    @Bindable var model: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: WorkReference.Scope?
    @State private var draftCount = 0
    @State private var queuedCount = 0
    @State private var document: WorkUnsentDocument?
    @State private var exporting = false
    @State private var message: String?

    private struct Export: Encodable {
        let version = 1
        let drafts: [ChatDraft]
        let queues: [ChatOutboxStore.Queue]
    }

    var body: some View {
        ThemedSheet(title: L10n.text("apple.workunsentwriting.sign_out_of_this_device.5c5bf797"), subtitle: L10n.text("apple.workunsentwriting.your_unsent_writing_stays_here.4b64f583"), icon: .signOut,
                    scrolls: true, onClose: { if !model.isSigningOut { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.workunsentwriting.saved_work_copies_will_be_removed_from_thi.c722dcc6"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                Text(L10n.text("apple.workunsentwriting.0_drafts_1_pending_messages.118b42f3", "\(draftCount)", "\(queuedCount)"))
                    .font(Theme.body.weight(.semibold))
                if draftCount + queuedCount > 0 {
                    Button(L10n.text("apple.workunsentwriting.export_unsent_writing.3d041a56"), .download) { prepareExport(); exporting = document != nil }
                        .buttonStyle(SecondaryButtonStyle())
                    Text(L10n.text("apple.workunsentwriting.the_export_contains_text_and_attachment_de.f3c68b07"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                Text(L10n.text("apple.workunsentwriting.account_usage_stays_you_will_need_to_appro.59351d7b"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
            .disabled(model.isSigningOut)
        } actions: {
            Button(L10n.text("apple.workunsentwriting.keep_working.5ed03f22"), .back) { dismiss() }
                .buttonStyle(SecondaryButtonStyle()).disabled(model.isSigningOut)
            Spacer()
            Button(model.isSigningOut ? L10n.text("apple.workunsentwriting.signing_out.08c6bd35") : L10n.text("common.sign_out"), .signOut) {
                Task {
                    guard scope == WorkSessionContext.shared.scope else { dismiss(); return }
                    await model.signOut()
                    if !model.signedIn { dismiss() }
                    else { message = model.errorMessage ?? L10n.text("apple.workunsentwriting.sign_out_could_not_be_completed_your_writi.bffeaeea") }
                }
            }
            .buttonStyle(DestructiveButtonStyle()).disabled(model.isSigningOut)
        }
        .modalFrame(width: 560, height: 480)
        .presentationBackground(Theme.background)
        .presentationDetents([.medium, .large])
        .task { scope = WorkSessionContext.shared.scope; prepareExport() }
        .onChange(of: WorkSessionContext.shared.scope) { _, value in
            if value != scope { document = nil; dismiss() }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "tokenstat-unsent-writing") { result in
            switch result {
            case .success: message = L10n.text("apple.workunsentwriting.unsent_writing_exported_originals_stay_on.1c9cf197")
            case .failure: message = L10n.text("apple.workunsentwriting.the_export_could_not_be_saved_your_writing.9f996c66")
            }
        }
    }

    private func prepareExport() {
        guard let scope, scope == WorkSessionContext.shared.scope else { document = nil; return }
        let drafts = ChatDraftStore.shared.drafts(in: scope)
        draftCount = drafts.count
        do {
            let queues = try ChatOutboxStore.shared.queues(in: scope)
            queuedCount = queues.reduce(0) { $0 + $1.items.count }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            document = WorkUnsentDocument(data: try encoder.encode(Export(drafts: drafts, queues: queues)))
        } catch {
            document = nil
            message = L10n.text("apple.workunsentwriting.some_pending_writing_could_not_be_read_for.3d5ca2ae")
        }
    }
}

struct WorkLegacyDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var listing = ChatLegacyQueueStore.Listing()
    @State private var pendingRemoval: ChatLegacyQueueStore.Draft?
    @State private var limit = 30
    @State private var message: String?

    var body: some View {
        ThemedSheet(title: L10n.text("apple.workunsentwriting.older_pending_drafts.9f27153b"), subtitle: L10n.text("apple.workunsentwriting.unassigned_writing_on_this_device.1152f514"), icon: .history,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.workunsentwriting.these_drafts_were_saved_before_queues_reco.e0a60039"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if listing.drafts.isEmpty && listing.unreadable == 0 {
                    Text(L10n.text("apple.workunsentwriting.there_are_no_older_pending_drafts_on_this.8fe823f7")).font(Theme.callout)
                }
                ForEach(Array(listing.drafts.prefix(limit))) { draft in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(draft.message.text.isEmpty ? L10n.text("apple.workunsentwriting.attachment_draft.9f5dcc06") : draft.message.text)
                            .font(Theme.callout).textSelection(.enabled).lineLimit(8)
                        if !draft.message.attachments.isEmpty {
                            Text(L10n.text("apple.workunsentwriting.attachments_0_recover_files_from_the_origi.89169949", "\(draft.message.attachments.map(\.name).joined(separator: ", "))"))
                                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { actions(draft) }
                            VStack(alignment: .leading) { actions(draft) }
                        }
                    }
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                }
                if listing.drafts.count > limit {
                    Button(L10n.text("apple.workunsentwriting.show_more_drafts.f5562a49"), .more) { limit += 30 }.buttonStyle(SecondaryButtonStyle())
                }
                if listing.unreadable > 0 {
                    Text(L10n.text("apple.workunsentwriting.some_older_records_could_not_be_read_they.db6fbff3"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
        }
        .modalFrame(width: 620, height: 660)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { listing = ChatLegacyQueueStore.list() }
        .confirmationDialog(L10n.text("apple.workunsentwriting.remove_this_older_draft_from_this_device.cc93372f"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button(L10n.text("apple.workunsentwriting.remove_local_copy.4d26e9f5"), role: .destructive) {
                guard let draft = pendingRemoval else { return }
                do { try ChatLegacyQueueStore.remove(draft); listing = ChatLegacyQueueStore.list() }
                catch { message = L10n.text("apple.workunsentwriting.the_draft_changed_or_could_not_be_removed.e031b20d") }
                pendingRemoval = nil
            }
        } message: { Text(L10n.text("apple.workunsentwriting.copy_any_writing_you_want_to_keep_first_no.5ea88885")) }
    }

    @ViewBuilder private func actions(_ draft: ChatLegacyQueueStore.Draft) -> some View {
        Button(L10n.text("apple.workunsentwriting.copy_text.b0ac9cea"), .copy) {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft.message.text, forType: .string)
            #else
            UIPasteboard.general.string = draft.message.text
            #endif
            message = L10n.text("apple.workunsentwriting.text_copied_review_the_destination_before.76f954fb")
        }.buttonStyle(SecondaryButtonStyle(small: true))
        Button(L10n.text("apple.workunsentwriting.remove_local_copy.4d26e9f5"), .delete) { pendingRemoval = draft }
            .buttonStyle(SecondaryButtonStyle(small: true))
    }
}
