// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct WorkFolderCacheButton: View {
    let folderID: String
    var peer: String? = nil
    let name: String
    @State private var destination: WorkFolderCacheSettings.Destination?

    var body: some View {
        Button("Saved work", .archive) {
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
        ThemedSheet(title: "Saved work", subtitle: current ? destination.name : "", icon: .archive,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Toggle("Save recent work on this device", isOn: $enabled)
                    .toggleStyle(.brandCheckbox)
                    .onChange(of: enabled) { _, value in
                        guard current else { return }
                        WorkCacheSettings.shared.setFolderEnabled(value, for: destination.reference)
                    }
                Text("Opened conversations and viewed changes are encrypted on this device. Turning this off stops new copies; existing copies stay until you clear them.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                if !WorkCacheSettings.shared.enabled {
                    Text("Saving is turned off for all folders in Settings. This folder’s choice will apply when saving is turned on again.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                ThemeRule()
                Text("\(records.count) saved items · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: records.reduce(UInt64(0)) { $0.saturatingAdd($1.bytes) }), countStyle: .file))")
                    .font(Theme.callout)
                Button("Clear this folder’s saved work", .delete) { Task { await clear() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || records.isEmpty)
                Text("Clearing removes copies from this device, including copies kept offline. Source work and unsent drafts stay.")
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
        } catch { if current { message = "Saved work could not be read. Close and try again." }; return false }
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
            message = records.isEmpty ? "Saved work cleared." : "New work was saved while clearing. Turn saving off to keep this folder clear."
        } catch { if current { message = "Some copies could not be removed. Try again." } }
    }
}
