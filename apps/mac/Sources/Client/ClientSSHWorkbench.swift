// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import Observation

#if !os(macOS)
/// One SSH workbench per login lifetime, shared by both adaptive layouts.
@MainActor @Observable
final class ClientSSHWorkbench {
    struct Connection: Identifiable {
        let id = UUID()
        let host: SSHHost
    }
    struct TerminalPresentation: Identifiable { let id = UUID() }

    let library: SSHLibraryModel
    let sessions: SSHSessionsModel
    var vault: SSHVaultModel { library.vault }
    var section = SSHLibraryView.Section.hosts
    var route: SSHLibraryRoute? {
        didSet {
            if oldValue != route, let oldValue { library.drafts.remove(oldValue) }
        }
    }
    var expanded: Set<String> = []
    var connection: Connection?
    var terminal: TerminalPresentation?
    var showingVault = false
    @ObservationIgnored private var active = true
    @ObservationIgnored private var pendingTerminal: TerminalPresentation?
    @ObservationIgnored private var pendingConnection: Connection?

    init(scope: WorkReference.Scope?) {
        let library = SSHLibraryModel(ownerScope: scope)
        self.library = library
        sessions = SSHSessionsModel(isOwnerCurrent: { library.ownership.claim() != nil })
    }

    func connect(_ host: SSHHost) {
        guard active, library.ownership.claim() != nil else { return }
        pendingTerminal = nil
        connection = Connection(host: host)
    }

    func connected(_ session: SSHLiveTerminal, from request: Connection) {
        guard active, connection?.id == request.id, library.ownership.claim() != nil else {
            session.detachPoll()
            return
        }
        sessions.adopt(session, startup: session.hostID.map { library.startupSnippets(for: $0) } ?? [])
        pendingTerminal = TerminalPresentation()
    }

    func connectionDidDismiss() {
        guard active, connection == nil, let next = pendingTerminal else { return }
        pendingTerminal = nil
        terminal = next
    }

    func newConnection(after session: SSHLiveTerminal) {
        guard active, let hostID = session.hostID,
              let host = library.hosts.first(where: { $0.id == hostID }) else { return }
        pendingConnection = Connection(host: host)
        terminal = nil
    }

    func terminalDidDismiss() {
        guard active, terminal == nil, let next = pendingConnection else { return }
        pendingConnection = nil
        connection = next
    }

    func setForeground(_ value: Bool) {
        sessions.setForeground(value)
        vault.setForeground(value)
    }

    func watch(tier: String?) async {
        guard active, library.ownership.claim() != nil else { return }
        async let load: Void = library.ensureLoaded(vaultTier: SSHLibraryModel.paidTier(for: tier))
        async let status: Void = vault.watch()
        await sessions.watch()
        _ = await (load, status)
    }

    func deactivate() {
        active = false
        library.deactivate()
        sessions.deactivate()
        connection = nil; terminal = nil; showingVault = false; route = nil
        pendingTerminal = nil; pendingConnection = nil
    }
}

/// Presenters stay above the branch replaced when the phone folds.
struct ClientSSHPresentations: ViewModifier {
    @Bindable var workbench: ClientSSHWorkbench
    let tier: String?

    func body(content: Content) -> some View {
        let request = workbench.connection
        let terminalRequest = workbench.terminal
        content
            .sheet(item: Binding(
                get: { workbench.connection },
                set: { value in
                    guard workbench.connection?.id == request?.id else { return }
                    workbench.connection = value
                }
            ), onDismiss: workbench.connectionDidDismiss) { request in
                SSHConnectForm(host: request.host, model: workbench.library) { session in
                    workbench.connected(session, from: request)
                }
            }
            .sheet(isPresented: $workbench.showingVault) {
                SSHVaultScreen(vault: workbench.vault, tier: tier ?? "",
                    canWrite: SSHLibraryModel.paidTier(for: tier) != nil, library: workbench.library)
            }
            .fullScreenCover(item: Binding(
                get: { workbench.terminal },
                set: { value in
                    guard workbench.terminal?.id == terminalRequest?.id else { return }
                    workbench.terminal = value
                }
            ), onDismiss: workbench.terminalDidDismiss) { _ in
                if let session = workbench.sessions.selected {
                    SSHLiveTerminalScreen(sessions: workbench.sessions, session: session,
                        library: workbench.library, onNewSession: {
                            workbench.newConnection(after: session)
                        })
                        .id(session.id)
                }
            }
    }
}
#endif
