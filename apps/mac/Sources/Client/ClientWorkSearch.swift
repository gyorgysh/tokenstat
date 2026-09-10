// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// The one way into search, in the top bar of every screen.
///
/// The glass alone, with the title kept for VoiceOver: this sits in a toolbar
/// beside the wordmark, where a word would crowd the one piece of brand the
/// client gets. Home used to carry a second, spelled-out copy under the
/// greeting, which is a button for something the bar above it already offers.
struct ClientWorkSearchButton: View {
    @Environment(ClientNavigationModel.self) private var navigation

    var body: some View {
        Button("Search", .search) { navigation.showWorkSearch = true }
            .labelStyle(.iconOnly)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Search")
    }
}

struct ClientWorkSearchPresentation: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkSearchModel?
    @State private var failure: String?
    @State private var preparing = false
    @State private var visible = false
    /// What has been typed while saved work is still opening, or after it
    /// refused to. The app's own screens are searchable either way: a saved
    /// store that will not open is exactly when somebody goes looking for the
    /// Saved work setting.
    @State private var placeQuery = ""
    @FocusState private var placeFieldFocused: Bool

    var body: some View {
        Group {
            if let model {
                WorkSearchSheet(model: model, open: open, places: places)
            } else {
                ThemedSheet(title: "Search", subtitle: "Find a screen, a setting, or your work",
                            icon: .search, scrolls: true, onClose: { dismiss() }) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        placeField
                        if preparing { ProgressView("Preparing saved work") }
                        if let failure {
                            Text(failure).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                            Button("Try again", .refresh) { Task { await prepare() } }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        ForEach(ClientAppPlaces.matches(placeQuery, machines: machines)) { place in
                            Button { openPlace(place) } label: { WorkSearchPlaceRow(place: place) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
                .task { placeFieldFocused = true }
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

    private var machines: [Machine] { account.account?.machines ?? [] }

    /// Screens and settings, searched beside the work in the shared sheet.
    private var places: WorkSearchPlaceSource {
        WorkSearchPlaceSource(
            matches: { ClientAppPlaces.matches($0, machines: machines) },
            open: { place in
                guard let destination = ClientAppPlaces.destination(of: place) else { return }
                // Recorded rather than opened. The account sheet is presented
                // from the same view as this one, and two sheets on one view
                // queue instead of stacking, so the root opens it once search
                // has closed. See `ClientRootView.openPendingPlace`.
                navigation.pendingPlace = destination
            }
        )
    }

    private var placeField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ActionIcon.search.symbol).foregroundStyle(Theme.controlGlyph)
            TextField("Search the app", text: $placeQuery)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($placeFieldFocused)
                // A screen's name is not a sentence, and a first word the
                // keyboard has corrected into another one finds nothing.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(Theme.Space.m)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
    }

    private func openPlace(_ place: WorkSearchPlace) {
        guard let destination = ClientAppPlaces.destination(of: place) else { return }
        navigation.pendingPlace = destination
        dismiss()
    }

    private func prepare() async {
        guard visible, !Task.isCancelled, !preparing, model == nil, account.signedIn,
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
            guard visible, !Task.isCancelled, account.signedIn, WorkSessionContext.shared.scope == scope,
                  WorkAccessStore.shared.generation == access,
                  Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == Set(machines.keys) else { return }
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
            await learn(scope: scope, hosts: allowed, access: access, linked: Set(machines.keys))
        } catch {
            guard visible, !Task.isCancelled, account.signedIn,
                  WorkSessionContext.shared.scope == scope,
                  WorkAccessStore.shared.generation == access,
                  Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == Set(machines.keys) else { return }
            failure = "Saved work could not be opened for search. Unlock this device and try again."
        }
    }

    /// Ask the machines this device may already open what folders they hold.
    ///
    /// A phone knows the folders it pinned and the ones it opened, which is a
    /// fraction of what is on a Mac, so a folder somebody has never tapped
    /// here was unfindable by name. The list comes from the machine that owns
    /// it, once when search opens rather than once per keystroke.
    ///
    /// **Verified hosts only, and no access is asked for.** A check would
    /// write a new answer into `WorkAccessStore`, and this sheet closes itself
    /// when that generation moves, so asking here would shut the search
    /// somebody just opened. Unknown stays unknown, as it does everywhere else.
    private func learn(scope: WorkReference.Scope, hosts: Set<String>,
                       access: UInt64, linked: Set<String>) async {
        guard !hosts.isEmpty else { return }
        var known: [WorkSearchCatalog.KnownFolder] = []
        var answered: Set<String> = []
        await withTaskGroup(of: (String, [WorkspaceFolder])?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let folders = try? await ClientRemote.folderList(peer: host) else { return nil }
                    return (host, folders)
                }
            }
            for await result in group {
                guard let (host, folders) = result else { continue }
                answered.insert(host)
                known += folders.map { folder in
                    WorkSearchCatalog.KnownFolder(
                        // The machine's own id, which is what a reference
                        // carries. Only the folder screens wear the
                        // `remote:<peer>:` prefix.
                        reference: WorkReference(scope: scope, hostIdentity: host,
                            workspaceID: folder.id, kind: .workspace, itemID: nil),
                        name: folder.name,
                        // A name, not a save. Dating it now would put "Saved a
                        // moment ago" under a folder nothing happened to, so it
                        // carries no time and the row prints none.
                        updatedAt: Date(timeIntervalSince1970: 0))
                }
            }
        }
        guard visible, !Task.isCancelled, account.signedIn, let model,
              WorkSessionContext.shared.scope == scope,
              WorkAccessStore.shared.generation == access,
              Set(account.account?.machines.compactMap(\.publicIdentity) ?? []) == linked else { return }
        await model.adopt(folders: known, live: answered)
    }

    private func open(_ reference: WorkReference) -> Bool {
        guard let scope = WorkSessionContext.shared.scope, reference.scope == scope,
              account.signedIn, WorkAccessStore.shared.allowed(scope: scope, host: reference.hostIdentity) == true,
              account.account?.machines.contains(where: { $0.publicIdentity == reference.hostIdentity }) == true else { return false }
        if reference.kind == .conversation, let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) {
            ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date()), for: reference)
        }
        navigation.destination = .workspaces
        navigation.restoredRoute = WorkMobileRoute(scope: scope, tab: "workspaces", reference: reference,
            section: reference.kind == .conversation ? "chat" : nil)
        return true
    }
}
#endif
