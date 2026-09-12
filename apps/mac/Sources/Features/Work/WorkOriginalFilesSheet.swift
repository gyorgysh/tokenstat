// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import UniformTypeIdentifiers

struct WorkOriginalFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct WorkOriginalFilesSheet: View {
    let scope: WorkReference.Scope
    @Environment(\.dismiss) private var dismiss
    @State private var files: [ChatLocalAttachmentStore.RetainedFile] = []
    @State private var inUse: Set<String> = []
    @State private var loading = true
    @State private var busy = false
    @State private var message: String?
    @State private var removal: ChatLocalAttachmentStore.RetainedFile?
    @State private var document: WorkOriginalFileDocument?
    @State private var exportName = "attachment"
    @State private var exporting = false
    @State private var limit = 30

    var body: some View {
        ThemedSheet(title: "Original draft files", subtitle: "Kept on this device", icon: .attach,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Originals stay here after sending, clearing saved work, or signing out. Export a file to keep it elsewhere. Saved drafts and pending messages are checked before removal.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if loading { ProgressView("Reading saved originals…") }
                else if files.isEmpty { Text("No original draft files are saved for this account.").font(Theme.callout) }
                else {
                    Text("\(files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: files.reduce(UInt64(0)) { $0.saturatingAdd(UInt64(clamping: $1.bytes)) }), countStyle: .file)) on this device")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    ForEach(Array(files.prefix(limit))) { file in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(file.attachment.name).font(Theme.callout.weight(.semibold)).textSelection(.enabled)
                            Text(inUse.contains(file.id) ? "Used by a draft or pending message" : "Retained original")
                                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            ViewThatFits(in: .horizontal) {
                                HStack { actions(file) }
                                VStack(alignment: .leading) { actions(file) }
                            }
                        }
                        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if files.count > limit {
                        Button("Show more files", .more) { limit += 30 }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
            .disabled(busy)
        }
        .modalFrame(width: 620, height: 660)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { await refresh() }
        .onChange(of: WorkSessionContext.shared.readingScope) { _, value in
            if value != scope { document = nil; files = []; dismiss() }
        }
        .confirmationDialog("Remove this retained original from this device?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        )) {
            Button("Remove original", role: .destructive) {
                guard let file = removal else { return }
                removal = nil
                Task { await remove(file) }
            }
        } message: { Text("Export it first if you want another copy. Files on the conversation’s computer are unchanged.") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: exportName) { result in
            document = nil
            switch result {
            case .success: message = "Original exported. The copy on this device remains here."
            case .failure: message = "Export could not be completed. The original is still here."
            }
        }
    }

    @ViewBuilder private func actions(_ file: ChatLocalAttachmentStore.RetainedFile) -> some View {
        Button("Export file", .download) {
            Task {
                busy = true
                defer { busy = false }
                do {
                    guard scope == WorkSessionContext.shared.readingScope else { return }
                    let data = try await ChatLocalAttachmentStore.shared.read(file.attachment, reference: file.reference)
                    guard scope == WorkSessionContext.shared.readingScope else { return }
                    document = WorkOriginalFileDocument(data: data)
                    exportName = ChatFileStaging.sanitized(file.attachment.name)
                    exporting = true
                } catch { message = "The original could not be opened. It has not been removed." }
            }
        }.buttonStyle(SecondaryButtonStyle(small: true))
        Button("Remove original", .delete) { removal = file }
            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(inUse.contains(file.id))
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await ChatLocalAttachmentStore.shared.retained(in: scope)
            guard scope == WorkSessionContext.shared.readingScope else { return }
            files = result.files
            inUse = Set(result.files.map(\.id))
            var protected = try ChatDraftStore.shared.protectedAttachments(in: scope)
            for queue in try ChatOutboxStore.shared.queues(in: scope) {
                guard let key = WorkReferenceKey.conversation(queue.reference) else { continue }
                protected[key, default: []].formUnion(queue.items.flatMap { $0.attachments.map(\.id) })
            }
            for file in result.files {
                guard let key = WorkReferenceKey.conversation(file.reference) else { continue }
                if protected[key]?.contains(file.attachment.id) != true { inUse.remove(file.id) }
            }
            if result.hasUnreadableFiles { message = "Some original records could not be read. They have been left untouched." }
        } catch { message = "Some original files or draft references could not be read. Removal stays unavailable until they can be checked." }
    }
    private func remove(_ file: ChatLocalAttachmentStore.RetainedFile) async {
        busy = true
        defer { busy = false }
        do {
            guard scope == WorkSessionContext.shared.readingScope else { return }
            let selectedScope = scope
            try await ChatLocalAttachmentStore.shared.remove(file) {
                guard selectedScope == WorkSessionContext.shared.readingScope else { throw CancellationError() }
                if try ChatDraftStore.shared.referencedAttachmentIDs(for: file.reference).contains(file.attachment.id) { return false }
                return try !ChatOutboxStore.shared.items(for: file.reference).contains {
                    $0.attachments.contains { $0.id == file.attachment.id }
                }
            }
            message = "Retained original removed from this device."
            await refresh()
        } catch ChatLocalAttachmentStore.Failure.removalUnconfirmed {
            message = ChatLocalAttachmentStore.Failure.removalUnconfirmed.localizedDescription
            await refresh()
        } catch ChatLocalAttachmentStore.Failure.inUse {
            message = "This file is now used by a draft or pending message. It has been kept."
            await refresh()
        } catch let error as OriginalFileCoordination.Failure {
            message = error.localizedDescription
        } catch { message = "The file changed or could not be removed. It has been kept; reopen this sheet to review it again." }
    }
}
