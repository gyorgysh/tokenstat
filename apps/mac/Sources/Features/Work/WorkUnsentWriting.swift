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
        ThemedSheet(title: "Sign out of this device?", subtitle: "Your unsent writing stays here", icon: .signOut,
                    scrolls: true, onClose: { if !model.isSigningOut { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Saved work copies will be removed from this device. Unsent drafts and pending messages stay with their original account and will not send while you are signed out.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                Text("\(draftCount) drafts · \(queuedCount) pending messages")
                    .font(Theme.body.weight(.semibold))
                if draftCount + queuedCount > 0 {
                    Button("Export unsent writing", .download) { prepareExport(); exporting = document != nil }
                        .buttonStyle(SecondaryButtonStyle())
                    Text("The export contains text and attachment details. Attachment file contents are not included.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                Text("Account usage stays. You will need to approve this device again when signing back in.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
            .disabled(model.isSigningOut)
        } actions: {
            Button("Keep working", .back) { dismiss() }
                .buttonStyle(SecondaryButtonStyle()).disabled(model.isSigningOut)
            Spacer()
            Button(model.isSigningOut ? "Signing out…" : "Sign out", .signOut) {
                Task {
                    guard scope == WorkSessionContext.shared.scope else { dismiss(); return }
                    await model.signOut()
                    if !model.signedIn { dismiss() }
                    else { message = model.errorMessage ?? "Sign-out could not be completed. Your writing stays here." }
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
            case .success: message = "Unsent writing exported. Originals stay on this device."
            case .failure: message = "The export could not be saved. Your writing stays on this device."
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
            message = "Some pending writing could not be read for export. It remains on this device; cancel sign-out and try again after unlocking."
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
        ThemedSheet(title: "Older pending drafts", subtitle: "Unassigned writing on this device", icon: .history,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("These drafts were saved before queues recorded their account and machine. They will never send automatically. Copy text only after choosing and reviewing the correct conversation.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if listing.drafts.isEmpty && listing.unreadable == 0 {
                    Text("There are no older pending drafts on this device.").font(Theme.callout)
                }
                ForEach(Array(listing.drafts.prefix(limit))) { draft in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(draft.message.text.isEmpty ? "Attachment draft" : draft.message.text)
                            .font(Theme.callout).textSelection(.enabled).lineLimit(8)
                        if !draft.message.attachments.isEmpty {
                            Text("Attachments: \(draft.message.attachments.map(\.name).joined(separator: ", ")). Recover files from the original conversation.")
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
                    Button("Show more drafts", .more) { limit += 30 }.buttonStyle(SecondaryButtonStyle())
                }
                if listing.unreadable > 0 {
                    Text("Some older records could not be read. They have been left untouched.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
        }
        .modalFrame(width: 620, height: 660)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { listing = ChatLegacyQueueStore.list() }
        .confirmationDialog("Remove this older draft from this device?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove local copy", role: .destructive) {
                guard let draft = pendingRemoval else { return }
                do { try ChatLegacyQueueStore.remove(draft); listing = ChatLegacyQueueStore.list() }
                catch { message = "The draft changed or could not be removed. Close and reopen to see its latest copy." }
                pendingRemoval = nil
            }
        } message: { Text("Copy any writing you want to keep first. Nothing on a workspace host will be changed.") }
    }

    @ViewBuilder private func actions(_ draft: ChatLegacyQueueStore.Draft) -> some View {
        Button("Copy text", .copy) {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft.message.text, forType: .string)
            #else
            UIPasteboard.general.string = draft.message.text
            #endif
            message = "Text copied. Review the destination before using it."
        }.buttonStyle(SecondaryButtonStyle(small: true))
        Button("Remove local copy", .delete) { pendingRemoval = draft }
            .buttonStyle(SecondaryButtonStyle(small: true))
    }
}
