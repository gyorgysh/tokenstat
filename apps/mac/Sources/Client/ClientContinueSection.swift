// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

extension Account {
    var recentPlacesScope: ClientRecentPlaces.Scope? {
        signedIn ? ClientRecentPlaces.Scope(host: host, handle: handle) : nil
    }
}

/// Home reads device history and the account only. No destination is mounted
/// until a row is opened; an asleep host cannot delay this section.
struct ClientContinueSection: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    private var places: [ClientRecentPlaces.Place] {
        Array(ClientRecentPlaces.shared.places(in: account.account?.recentPlacesScope).prefix(4))
    }

    var body: some View {
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Pick up where you left off", mark: "mark_activity")
                VStack(spacing: 0) {
                    ForEach(places) { place in
                        HStack(spacing: 0) {
                            NavigationLink {
                                ClientSavedPlaceView(place: place)
                            } label: {
                                row(place)
                            }
                            .buttonStyle(.plain)
                            if let reference = reference(for: place) {
                                PinToggleButton(
                                    reference: reference, label: place.title,
                                    folderName: place.workspaceName
                                )
                                .padding(.trailing, Theme.Space.xs)
                            }
                        }
                        if place.id != places.last?.id {
                            ThemeRule().padding(.horizontal, Theme.Space.m)
                        }
                    }
                }
                .cardSurface()
            }
            .accessibilityIdentifier("home.continue")
        }
    }

    /// What a pin files this row under. Terminal sessions end, so they are
    /// not pinnable: keeping a link to a dead shell is worse than no pin.
    private func reference(for place: ClientRecentPlaces.Place) -> WorkReference? {
        guard let scope = account.account?.pinnedWorkScope,
              let workspaceID = place.id.workspaceID, !workspaceID.isEmpty
        else { return nil }
        let kind: WorkReference.Kind
        switch place.id.kind {
        case .workspace: kind = .workspace
        case .chat: kind = .conversation
        case .terminal: return nil
        }
        let itemID: String?
        switch kind {
        case .workspace: itemID = nil
        case .conversation, .terminal, .commit, .savedDiff:
            guard let item = place.id.itemID, !item.isEmpty else { return nil }
            itemID = item
        }
        return WorkReference(
            scope: scope, hostIdentity: place.id.peer, workspaceID: workspaceID,
            kind: kind, itemID: itemID
        )
    }

    private func row(_ place: ClientRecentPlaces.Place) -> some View {
        let machine = account.account?.machines.first { $0.publicIdentity == place.id.peer }
        let state = connectivity.isOffline ? "Asleep"
            : machine == nil ? "No longer linked"
            : machine?.online == true ? "Awake"
            : machine?.online == false ? "Asleep" : "Status unknown"
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: place.symbol)
                .font(ClientType.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(place.title)
                    .font(ClientType.label.weight(.semibold))
                    .lineLimit(2)
                (Text("\(machine?.displayName ?? "Machine") · \(state) · ")
                    + Text(place.openedAt, style: .relative))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension ClientRecentPlaces.Place {
    var title: String {
        switch id.kind {
        case .workspace: return workspaceName
        case .chat: return "Chat in \(workspaceName)"
        case .terminal: return id.workspaceID == nil ? "Terminal" : "Terminal in \(workspaceName)"
        }
    }
    var symbol: String {
        switch id.kind {
        case .workspace: return "folder"
        case .chat: return "bubble.left.and.bubble.right"
        case .terminal: return "terminal"
        }
    }
}

/// Shared by the phone's pushed workspace and the iPad's section destination.
/// Recording on appearance also covers device-detail links, which do not go
/// through the sidebar's navigation model.
private struct RememberWorkspace: ViewModifier {
    @Environment(AccountModel.self) private var account
    let peer: String
    let folder: WorkspaceFolder
    func body(content: Content) -> some View {
        content.onAppear {
            ClientRecentPlaces.shared.record(
                in: account.account?.recentPlacesScope, peer: peer,
                workspaceID: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id,
                workspaceName: folder.name, kind: .workspace
            )
        }
    }
}

extension View {
    func rememberWorkspace(peer: String, folder: WorkspaceFolder) -> some View {
        modifier(RememberWorkspace(peer: peer, folder: folder))
    }
}
#endif
