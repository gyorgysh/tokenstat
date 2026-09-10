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
    @State private var searchModel: WorkSearchModel?
    @State private var showSearch = false
    @State private var path: [WorkReference] = []

    private struct SavedRow: Identifiable {
        let reference: WorkReference
        let title: String
        let savedAt: Date
        var id: WorkReference { reference }
    }
    private var stillOwned: Bool { SavedWorkAccess.shared.reader == owner }

    var body: some View {
        NavigationStack(path: $path) {
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
                        ClientEmptyState(kind: .nothingYet, title: "No saved work",
                            message: "Conversations and changes you open while connected can be kept here for later.")
                    }
                    ForEach(rows) { row in
                        NavigationLink(value: row.reference) {
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
            .navigationDestination(for: WorkReference.self) { reference in
                if reference.kind == .conversation {
                    ClientSavedWorkConversation(reference: reference, hostName: owner.hosts[reference.hostIdentity] ?? "Machine")
                } else {
                    ClientSavedChangeDestination(reference: reference, owner: owner)
                }
            }
            .sheet(isPresented: $showSearch) {
                if let searchModel {
                    WorkSearchSheet(model: searchModel) { reference in
                        guard stillOwned, reference.scope == owner.scope else { return false }
                        path.append(reference)
                        return true
                    }
                }
            }
            .navigationTitle("Saved work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Search work", .search) { Task { await openSearch() } }
                        .disabled(loading)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { if !loaded { await load() } }
            .onChange(of: stillOwned) { _, value in
                if !value { rows = []; path = []; searchModel?.close(); dismiss() }
            }
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
                guard record.scope == scope,
                      let reference = WorkCache.reference(recordID: record.id, scope: owner.scope),
                      WorkCache.matches(kind: record.kind, reference: reference),
                      reference.itemID == record.itemId else { return false }
                return owner.hosts[reference.hostIdentity] != nil && WorkCacheAccess.canRead(reference)
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
            let row: SavedRow?
            if reference.kind == .conversation {
                let copy = await WorkCacheStore.shared.savedConversation(for: reference)
                row = copy.map { SavedRow(reference: reference, title: $0.title, savedAt: $0.savedAt) }
            } else if WorkCacheAccess.canRead(reference), let key = WorkCacheKey.existingKey(for: record.scope),
                      let copy = try? await Bridge.cachedChange(key: WorkCacheKey.encoded(key), scope: record.scope, id: record.id),
                      WorkCacheAccess.canRead(reference), copy.matches(reference) {
                row = SavedRow(reference: reference, title: copy.payload.title, savedAt: copy.payload.capturedAt)
            } else { row = nil }
            guard stillOwned, generation == SavedWorkAccess.shared.generation, !Task.isCancelled else { return }
            offset += 1
            if let row { rows.append(row) } else { unavailable += 1 }
        }
    }
    private func openSearch() async {
        guard stillOwned else { return }
        let generation = SavedWorkAccess.shared.generation
        let access = WorkAccessStore.shared.generation
        let catalog = WorkSearchCatalog(scope: owner.scope, linkedMachines: owner.hosts,
            allowedHosts: Set(owner.hosts.keys.filter { WorkAccessStore.shared.allowed(scope: owner.scope, host: $0) != false }), knownFolders: [], records: records)
        searchModel = WorkSearchModel(scope: owner.scope, folders: catalog.folders,
            machines: catalog.machines, metadata: [], includesSavedText: WorkCacheSettings.shared.enabled,
            ownsSession: { SavedWorkAccess.shared.reader == owner && SavedWorkAccess.shared.generation == generation
                && WorkAccessStore.shared.generation == access })
        showSearch = true
    }

}

private struct ClientSavedChangeDestination: View {
    let reference: WorkReference
    let owner: SavedWorkOwner
    @State private var change: WorkViewedChange?
    @State private var loaded = false
    var body: some View {
        Group {
            if let change {
                WorkViewedChangeSheet(change: change, ownsSession: { SavedWorkAccess.shared.reader == owner })
            } else if loaded {
                Text("This saved change is no longer available.").font(Theme.callout)
            } else { ProgressView("Opening saved change") }
        }
        .task {
            defer { loaded = true }
            let scope = WorkCache.scope(for: reference.scope)
            guard SavedWorkAccess.shared.reader == owner, WorkCacheAccess.canRead(reference),
                  let id = WorkCache.recordID(for: reference),
                  let key = WorkCacheKey.existingKey(for: scope),
                  let record = try? await Bridge.cachedChange(key: WorkCacheKey.encoded(key), scope: scope, id: id),
                  SavedWorkAccess.shared.reader == owner, WorkCacheAccess.canRead(reference), !Task.isCancelled, record.matches(reference) else { return }
            change = record.payload
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
            if WorkCacheAccess.canRead(reference), model.savedCopy != nil, let id = reference.itemID {
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
            _ = model.restoreSearchReadingPosition(reference)
            loaded = true
        }
    }
}
#endif
