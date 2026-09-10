// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientWorkSearchButton: View {
    @Environment(ClientNavigationModel.self) private var navigation
    var compact = false
    var body: some View {
        Group {
            if compact { button.keyboardShortcut("k", modifiers: .command) }
            else { button }
        }
    }

    private var button: some View {
        Button("Search work", .search) { navigation.showWorkSearch = true }
            .labelStyle(SearchLabelStyle(compact: compact))
            .accessibilityLabel("Search work")
    }

    private struct SearchLabelStyle: LabelStyle {
        let compact: Bool
        func makeBody(configuration: Configuration) -> some View {
            HStack { configuration.icon; if !compact { configuration.title } }
        }
    }
}

struct ClientWorkSearchPresentation: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkSearchModel?
    @State private var failure: String?
    @State private var preparing = false

    var body: some View {
        Group {
            if let model {
                WorkSearchSheet(model: model, open: open)
            } else {
                ThemedSheet(title: "Search work", subtitle: "Saved work on this device", icon: .search,
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
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
            }
        }
        .task { await prepare() }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in model?.close(); dismiss() }
        .onChange(of: WorkAccessStore.shared.generation) { _, _ in model?.close(); dismiss() }
        .onChange(of: account.account?.machines.compactMap(\.publicIdentity)) { _, _ in model?.close(); dismiss() }
    }

    private func prepare() async {
        guard !preparing, model == nil, account.signedIn,
              let scope = WorkSessionContext.shared.scope, let value = account.account else { return }
        preparing = true
        failure = nil
        defer { preparing = false }
        let access = WorkAccessStore.shared.generation
        let machines = value.machines.reduce(into: [String: String]()) { result, machine in
            if let identity = machine.publicIdentity { result[identity] = machine.displayName }
        }
        let allowed = Set(machines.keys.filter { WorkAccessStore.shared.allowed(scope: scope, host: $0) == true })
        let pins = PinnedWorkStore.shared.pins(in: scope)
        var known = pins.map {
            WorkSearchCatalog.KnownFolder(reference: $0.reference, name: $0.folderName, updatedAt: $0.pinnedAt)
        }
        let recentScope = ClientRecentPlaces.Scope(host: value.host, handle: value.handle)
        known += ClientRecentPlaces.shared.places(in: recentScope).compactMap { place in
            guard let folder = place.id.workspaceID else { return nil }
            return .init(reference: WorkReference(scope: scope, hostIdentity: place.id.peer,
                workspaceID: folder, kind: .workspace, itemID: nil), name: place.workspaceName, updatedAt: place.openedAt)
        }
        do {
            let includesText = WorkCacheSettings.shared.enabled
            let records = includesText ? try await Bridge.cacheList(scope: WorkCache.scope(for: scope)).records : []
            guard !Task.isCancelled, account.signedIn, WorkSessionContext.shared.scope == scope,
                  WorkAccessStore.shared.generation == access else { return }
            let catalog = WorkSearchCatalog(scope: scope, linkedMachines: machines, allowedHosts: allowed,
                                            knownFolders: known, records: records)
            let model = WorkSearchModel(scope: scope, folders: catalog.folders, machines: catalog.machines,
                metadata: catalog.metadata, includesSavedText: includesText, liveHosts: allowed, ownsSession: {
                    account.signedIn && WorkSessionContext.shared.scope == scope
                        && WorkAccessStore.shared.generation == access
                        && Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == Set(machines.keys)
                })
            model.coverageNotice = allowed.count < machines.count
                ? "Search covers machines with verified workspace access. Open a folder on another machine to verify its access."
                : (includesText ? nil : "Saved conversation text is off. Search covers folder information kept on this device.")
            self.model = model
        } catch {
            guard WorkSessionContext.shared.scope == scope, !Task.isCancelled else { return }
            failure = "Saved work could not be opened for search. Unlock this device and try again."
        }
    }

    private func open(_ reference: WorkReference) -> Bool {
        guard let scope = WorkSessionContext.shared.scope, reference.scope == scope,
              account.signedIn, WorkAccessStore.shared.allowed(scope: scope, host: reference.hostIdentity) == true,
              account.account?.machines.contains(where: { $0.publicIdentity == reference.hostIdentity }) == true else { return false }
        if reference.kind == .conversation, let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) {
            ChatReadingStore.shared.remember(.init(eventID: anchor, offset: 0, updatedAt: Date()), for: reference)
        }
        navigation.destination = .workspaces
        navigation.restoredRoute = WorkMobileRoute(scope: scope, tab: "workspaces", reference: reference,
            section: reference.kind == .conversation ? "chat" : nil)
        return true
    }
}
#endif
