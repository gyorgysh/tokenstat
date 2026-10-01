// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct WorkFolderCacheButton: View {
    let folderID: String
    var peer: String? = nil
    let name: String
    @State private var destination: WorkFolderCacheSettings.Destination?

    var body: some View {
        Button(L10n.text("apple.workfoldercachesettings.saved_work.9204cce7"), .archive) {
            if let reference = WorkViewedChange.owner(folderID: folderID, peer: peer) {
                destination = .init(reference: reference, name: name)
            }
        }
        .sheet(item: $destination) { WorkFolderCacheSettings(destination: $0) }
    }
}

struct WorkFolderCacheSettings: View {
    struct Destination: Identifiable {
        let reference: WorkReference
        let name: String
        var id: WorkReference { reference }
    }
    let destination: Destination
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = true
    @State private var records: [CacheRecordMeta] = []
    @State private var busy = false
    @State private var message: String?

    private var current: Bool { WorkCacheAccess.canRead(destination.reference) }

    var body: some View {
        ThemedSheet(title: L10n.text("apple.workfoldercachesettings.saved_work.9204cce7"), subtitle: current ? destination.name : "", icon: .archive,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Toggle(L10n.text("apple.workfoldercachesettings.save_recent_work_on_this_device.e5e4effd"), isOn: $enabled)
                    .toggleStyle(.brandCheckbox)
                    .onChange(of: enabled) { _, value in
                        guard current else { return }
                        WorkCacheSettings.shared.setFolderEnabled(value, for: destination.reference)
                    }
                Text(L10n.text("apple.workfoldercachesettings.opened_conversations_and_viewed_changes_ar.70045bee"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if !WorkCacheSettings.shared.enabled {
                    Text(L10n.text("apple.workfoldercachesettings.saving_is_turned_off_for_all_folders_in_se.47813aa8"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                ThemeRule()
                Text(L10n.text("apple.workfoldercachesettings.0_saved_items_1.6298b5c1", "\(records.count)", "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: records.reduce(UInt64(0)) { $0.saturatingAdd($1.bytes) }), countStyle: .file))"))
                    .font(Theme.callout)
                Button(L10n.text("apple.workfoldercachesettings.clear_this_folder_s_saved_work.562d133f"), .delete) { Task { await clear() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || records.isEmpty)
                Text(L10n.text("apple.workfoldercachesettings.clearing_removes_copies_from_this_device_i.1f1e89ff"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
            }
            .disabled(!current)
        }
        .onChange(of: current) { _, value in if !value { records = []; dismiss() } }
        .modalFrame(width: 520, height: 460)
        .presentationBackground(Theme.background)
        .presentationDetents([.medium, .large])
        .task {
            enabled = WorkCacheSettings.shared.folderEnabled(destination.reference)
            await load()
        }
    }

    @discardableResult private func load() async -> Bool {
        guard current else { return false }
        do {
            let scope = destination.reference.scope
            let listing = try await Bridge.cacheList(scope: WorkCache.scope(for: scope))
            guard current, !Task.isCancelled else { return false }
            records = listing.records.filter {
                guard let ref = WorkCache.reference(recordID: $0.id, scope: scope)
                    ?? WorkSavedPreview.reference(recordID: $0.id, scope: scope) else { return false }
                return ref.hostIdentity == destination.reference.hostIdentity
                    && ref.workspaceID == destination.reference.workspaceID
            }
            return true
        } catch { if current { message = L10n.text("apple.workfoldercachesettings.saved_work_could_not_be_read_close_and_try.3b322b0b") }; return false }
    }

    private func clear() async {
        guard current, !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            // Refresh before deletion so copies saved while the sheet was open
            // are included. Every operation remains bound to this folder/scope.
            guard await load() else { return }
            for record in records {
                guard current, !Task.isCancelled else { return }
                _ = try await Bridge.cacheRemove(scope: record.scope, id: record.id)
            }
            guard current else { return }
            guard await load() else { return }
            message = records.isEmpty ? L10n.text("apple.workfoldercachesettings.saved_work_cleared.489ad926") : L10n.text("apple.workfoldercachesettings.new_work_was_saved_while_clearing_turn_sav.adcc538b")
        } catch { if current { message = L10n.text("apple.workfoldercachesettings.some_copies_could_not_be_removed_try_again.07f2b8a4") } }
    }
}
