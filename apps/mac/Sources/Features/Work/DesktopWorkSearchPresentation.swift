// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI

struct DesktopWorkSearchPresentation: View {
    let account: AccountModel
    let workspaces: WorkspacesModel
    let open: (WorkReference) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkSearchModel?
    @State private var failure: String?
    @State private var preparing = false
    @State private var visible = false

    var body: some View {
        Group {
            if let model {
                WorkSearchSheet(model: model, open: open)
            } else {
                ThemedSheet(title: "Search work", subtitle: "Saved work on this Mac", icon: .search,
                            onClose: { dismiss() }) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if preparing { ProgressView("Preparing saved work") }
                        if let failure {
                            Text(failure).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                            Button("Try again", .refresh) { Task { await prepare() } }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .modalFrame(width: 680, height: 720)
            }
        }
        // `visible` is set here as well as in `onAppear`, because the task
        // can run first: it guards every step of the preparation, and a task
        // that starts with it false gives up before doing anything and never
        // runs again. That is a search sheet that never opens its saved work.
        .task { visible = true; await prepare() }
        .onAppear { visible = true }
        .onDisappear { visible = false; model?.close() }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in model?.close(); dismiss() }
        .onChange(of: WorkAccessStore.shared.generation) { _, _ in model?.close(); dismiss() }
        .onChange(of: account.account?.machines.compactMap(\.publicIdentity)) { _, _ in model?.close(); dismiss() }
    }

    private func prepare() async {
        guard visible, !Task.isCancelled, !preparing, model == nil,
              let scope = WorkSessionContext.shared.scope else { return }
        preparing = true
        failure = nil
        defer { preparing = false }
        await WorkSessionContext.shared.resolveLocalHostIdentity()
        guard visible, !Task.isCancelled, WorkSessionContext.shared.scope == scope else { return }
        guard let local = WorkSessionContext.shared.localHostIdentity else {
            failure = "This Mac’s identity could not be loaded. Try again."
            return
        }
        let access = WorkAccessStore.shared.generation
        let linked = Set(account.account?.machines.compactMap(\.publicIdentity) ?? [])
        var machines = account.account?.machines.reduce(into: [String: String]()) { result, machine in
            if let identity = machine.publicIdentity { result[identity] = machine.displayName }
        } ?? [:]
        machines[local] = "This Mac"
        var allowed = Set(machines.keys.filter { WorkAccessStore.shared.allowed(scope: scope, host: $0) == true })
        allowed.insert(local)
        var known = PinnedWorkStore.shared.pins(in: scope).map {
            WorkSearchCatalog.KnownFolder(reference: $0.reference, name: $0.folderName, updatedAt: $0.pinnedAt)
        }
        known += workspaces.folders.compactMap { folder in
            let route = WorkDestinationResolver.route(folderID: folder.id)
            return .init(reference: WorkReference(scope: scope, hostIdentity: route.peer ?? local,
                workspaceID: route.workspaceID, kind: .workspace, itemID: nil), name: folder.name, updatedAt: Date())
        }
        let includesText = WorkCacheSettings.shared.enabled
        var records: [CacheRecordMeta] = []
        var savedUnavailable = false
        if includesText {
            do { records = try await Bridge.cacheList(scope: WorkCache.scope(for: scope)).records }
            catch { savedUnavailable = true }
        }
        guard visible, !Task.isCancelled, WorkSessionContext.shared.scope == scope,
              WorkAccessStore.shared.generation == access,
              Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == linked else { return }
        let catalog = WorkSearchCatalog(scope: scope, linkedMachines: machines, allowedHosts: allowed,
                                        knownFolders: known, records: records)
        let model = WorkSearchModel(scope: scope, folders: catalog.folders, machines: catalog.machines,
            metadata: catalog.metadata, includesSavedText: includesText, liveHosts: allowed.subtracting([local]), localHost: local, ownsSession: {
                WorkSessionContext.shared.scope == scope && WorkAccessStore.shared.generation == access
                    && Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == linked
            })
        model.coverageNotice = allowed.count < machines.count
            ? "Search covers this Mac and machines with verified workspace access. Open a folder on another machine to verify its access."
            : (includesText ? nil : "Saving conversation text is off. Search still includes work stored on this Mac.")
        if savedUnavailable {
            model.coverageNotice = "Saved copies could not be loaded. You can still search work stored on this Mac."
        }
        self.model = model
    }
}
#endif
