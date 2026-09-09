// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// A device-local library, reached explicitly when account verification failed.
/// Listing and opening call only the local cache, never a workspace host.
struct ClientSavedWorkView: View {
    let owner: SavedWorkOwner
    @Environment(\.dismiss) private var dismiss
    @State private var records: [CacheRecordMeta] = []
    @State private var rows: [SavedRow] = []
    @State private var offset = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var unavailable = 0

    private struct SavedRow: Identifiable {
        let reference: WorkReference
        let title: String
        let savedAt: Date
        var id: WorkReference { reference }
    }
    private var stillOwned: Bool { SavedWorkAccess.shared.reader == owner }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Saved for \(owner.name)")
                        .font(Theme.title.weight(.semibold))
                    Text("Copies kept on this device. Read, copy, or draft a reply here. Verify your account to return to live work.")
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                    if let failure {
                        ClientErrorCard(message: failure) { Task { await load() } }
                    } else if loaded, records.isEmpty {
                        ClientEmptyState(kind: .nothingYet, title: "No saved conversations",
                            message: "Conversations you open while connected can be kept here for later.")
                    }
                    ForEach(rows) { row in
                        NavigationLink {
                            ClientSavedWorkConversation(reference: row.reference,
                                hostName: owner.hosts[row.reference.hostIdentity] ?? "Machine")
                        } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: ActionIcon.archive.symbol)
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(row.title).font(ClientType.label.weight(.semibold)).lineLimit(2)
                                    Text(owner.hosts[row.reference.hostIdentity] ?? "Machine")
                                        .font(ClientType.caption).foregroundStyle(.secondary)
                                    Text("Saved \(RelativeClock.phrase(for: row.savedAt, style: .full))")
                                        .font(ClientType.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: ActionIcon.next.symbol).foregroundStyle(Theme.accent)
                            }
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .cardSurface()
                        }
                        .buttonStyle(.plain)
                    }
                    if loading {
                        ClientWireframe.Rows(count: 3)
                    } else if offset < records.count {
                        Button("Show more", .more) { Task { await loadNext() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    if unavailable > 0 {
                        Text("Some saved copies could not be opened. They may have been removed or may need this device to be unlocked.")
                            .font(ClientType.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .navigationTitle("Saved work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { if !loaded { await load() } }
        }
    }

    private func load() async {
        guard stillOwned, !loading else { return }
        let generation = SavedWorkAccess.shared.generation
        loading = true
        failure = nil
        defer { loading = false }
        let scope = WorkCache.scope(for: owner.scope)
        do {
            let result = try await Bridge.cacheList(scope: scope)
            guard stillOwned, generation == SavedWorkAccess.shared.generation, !Task.isCancelled else { return }
            records = result.records.filter { record in
                guard record.scope == scope, record.kind == "conversation",
                      let reference = WorkCache.reference(recordID: record.id, scope: owner.scope),
                      reference.itemID == record.itemId else { return false }
                return owner.hosts[reference.hostIdentity] != nil
            }.sorted { $0.updatedMs > $1.updatedMs }
            guard records.isEmpty || WorkCacheKey.existingKey(for: scope) != nil else {
                failure = "Saved work is unavailable on this device. Unlock it and try again, or verify your account when you can connect."
                return
            }
            rows = []
            offset = 0
            unavailable = 0
            loaded = true
            loading = false
            await loadNext()
        } catch {
            guard stillOwned, !Task.isCancelled else { return }
            failure = "Saved work could not be read. Try again on this device."
        }
    }

    private func loadNext() async {
        guard stillOwned, !loading else { return }
        let generation = SavedWorkAccess.shared.generation
        loading = true
        defer { loading = false }
        let end = min(offset + 20, records.count)
        while offset < end {
            guard stillOwned, generation == SavedWorkAccess.shared.generation, !Task.isCancelled else { return }
            let record = records[offset]
            guard let reference = WorkCache.reference(recordID: record.id, scope: owner.scope) else {
                offset += 1
                continue
            }
            let copy = await WorkCacheStore.shared.savedConversation(for: reference)
            guard stillOwned, generation == SavedWorkAccess.shared.generation, !Task.isCancelled else { return }
            offset += 1
            if let copy {
                rows.append(SavedRow(reference: reference, title: copy.title, savedAt: copy.savedAt))
            } else {
                unavailable += 1
            }
        }
    }
}

private struct ClientSavedWorkConversation: View {
    let reference: WorkReference
    let hostName: String
    @State private var model = ChatModel()
    @State private var loaded = false

    var body: some View {
        Group {
            if model.savedCopy != nil, let id = reference.itemID {
                ClientChatThread(model: model, chatID: id, folderName: "", hostName: hostName)
            } else if loaded {
                ClientEmptyState(kind: .unreachable, title: "Saved copy unavailable",
                    message: "This copy could not be opened. Any draft you saved is kept separately on this device.")
                    .padding(Theme.Space.m)
            } else {
                ClientWireframe.Rows(count: 5).padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        .task {
            _ = await model.loadSavedConversation(reference)
            loaded = true
        }
    }
}
#endif
