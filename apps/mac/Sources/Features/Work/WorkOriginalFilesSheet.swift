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
        ThemedSheet(title: L10n.text("apple.workoriginalfilessheet.original_draft_files.1093f37b"), subtitle: L10n.text("apple.workoriginalfilessheet.kept_on_this_device.cd773d4c"), icon: .attach,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.workoriginalfilessheet.originals_stay_here_after_sending_clearing.70513676"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if loading { ProgressView(L10n.text("apple.workoriginalfilessheet.reading_saved_originals.c8c14bc0")) }
                else if files.isEmpty { Text(L10n.text("apple.workoriginalfilessheet.no_original_draft_files_are_saved_for_this.f6c40297")).font(Theme.callout) }
                else {
                    Text(L10n.text("apple.workoriginalfilessheet.0_files_1_on_this_device.30ddc176", "\(files.count)", "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: files.reduce(UInt64(0)) { $0.saturatingAdd(UInt64(clamping: $1.bytes)) }), countStyle: .file))"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    ForEach(Array(files.prefix(limit))) { file in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(file.attachment.name).font(Theme.callout.weight(.semibold)).textSelection(.enabled)
                            Text(inUse.contains(file.id) ? L10n.text("apple.workoriginalfilessheet.used_by_a_draft_or_pending_message.ddb20ebe") : L10n.text("apple.workoriginalfilessheet.retained_original.28d0bbfd"))
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
                        Button(L10n.text("apple.workoriginalfilessheet.show_more_files.cf390073"), .more) { limit += 30 }.buttonStyle(SecondaryButtonStyle())
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
        .confirmationDialog(L10n.text("apple.workoriginalfilessheet.remove_this_retained_original_from_this_de.adf121c9"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        )) {
            Button(L10n.text("apple.workoriginalfilessheet.remove_original.b34e1154"), role: .destructive) {
                guard let file = removal else { return }
                removal = nil
                Task { await remove(file) }
            }
        } message: { Text(L10n.text("apple.workoriginalfilessheet.export_it_first_if_you_want_another_copy_f.6901d135")) }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: exportName) { result in
            document = nil
            switch result {
            case .success: message = L10n.text("apple.workoriginalfilessheet.original_exported_the_copy_on_this_device.df7aeea8")
            case .failure: message = L10n.text("apple.workoriginalfilessheet.export_could_not_be_completed_the_original.6699e035")
            }
        }
    }

    @ViewBuilder private func actions(_ file: ChatLocalAttachmentStore.RetainedFile) -> some View {
        Button(L10n.text("apple.workoriginalfilessheet.export_file.d9d979c6"), .download) {
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
                } catch { message = L10n.text("apple.workoriginalfilessheet.the_original_could_not_be_opened_it_has_no.b4b88550") }
            }
        }.buttonStyle(SecondaryButtonStyle(small: true))
        Button(L10n.text("apple.workoriginalfilessheet.remove_original.b34e1154"), .delete) { removal = file }
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
            if result.hasUnreadableFiles { message = L10n.text("apple.workoriginalfilessheet.some_original_records_could_not_be_read_th.3a92c296") }
        } catch { message = L10n.text("apple.workoriginalfilessheet.some_original_files_or_draft_references_co.e09752f8") }
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
            message = L10n.text("apple.workoriginalfilessheet.retained_original_removed_from_this_device.91b11019")
            await refresh()
        } catch ChatLocalAttachmentStore.Failure.removalUnconfirmed {
            message = ChatLocalAttachmentStore.Failure.removalUnconfirmed.localizedDescription
            await refresh()
        } catch ChatLocalAttachmentStore.Failure.inUse {
            message = L10n.text("apple.workoriginalfilessheet.this_file_is_now_used_by_a_draft_or_pendin.1d6766bc")
            await refresh()
        } catch let error as OriginalFileCoordination.Failure {
            message = error.localizedDescription
        } catch { message = L10n.text("apple.workoriginalfilessheet.the_file_changed_or_could_not_be_removed_i.241cc7d9") }
    }
}
