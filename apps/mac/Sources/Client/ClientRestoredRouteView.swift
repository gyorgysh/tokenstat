// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Re-resolve stored identifiers through the same availability gate as Continue.
/// A terminal reference attaches only to an existing session; no launch request
/// is reconstructed from navigation storage.
struct ClientRestoredRouteView: View {
    let route: WorkMobileRoute
    @Environment(ClientNavigationModel.self) private var navigation

    var body: some View {
        if route.scope == WorkSessionContext.shared.scope,
           let reader = navigation.restoredChatReader, reader.matches(route) {
            retainedReader(reader)
                .environment(\.clientChatPresentationID, reader.presentationID ?? reader.id)
                .id(reader.id)
        } else if route.scope == WorkSessionContext.shared.scope,
           let reference = route.reference, let place = place(reference) {
            ClientSavedPlaceView(place: place,
                restoredSection: reference.kind == .workspace
                    ? route.section.flatMap(WorkspaceSection.init(rawValue:)) : nil,
                onRestoredTerminalClose: reference.kind == .terminal
                    ? { navigation.restoredRoute = nil } : nil)
                .id(route)
        } else {
            ClientEmptyState(kind: .unreachable, title: L10n.text("apple.clientrestoredrouteview.this_place_is_unavailable.4b4de423"),
                message: L10n.text("apple.clientrestoredrouteview.return_to_your_projects_to_choose_where_to.d0ff81a3"))
                .padding(Theme.Space.m)
        }
    }

    @ViewBuilder private func retainedReader(_ reader: ClientChatLayoutHandoff.Reader) -> some View {
        if reader.key.conversation == nil {
            ClientChatView(peer: reader.key.peer, workspaceID: reader.key.workspace,
                folderName: reader.folderName, hostName: reader.hostName, retainedSession: reader.session)
        } else if let id = reader.reference.itemID {
            ClientRecentChatView(peer: reader.key.peer, workspaceID: reader.key.workspace,
                folderName: reader.folderName, hostName: reader.hostName, chatID: id, retainedSession: reader.session)
        }
    }

    private func place(_ reference: WorkReference) -> ClientRecentPlaces.Place? {
        let kind: ClientRecentPlaces.Kind
        switch reference.kind {
        case .workspace: kind = .workspace
        case .conversation: kind = .chat
        case .terminal: kind = .terminal
        default: return nil
        }
        return ClientRecentPlaces.Place(id: .init(peer: reference.hostIdentity,
            workspaceID: reference.workspaceID, kind: kind, itemID: reference.itemID),
            workspaceName: L10n.text("apple.clientrestoredrouteview.project.98595978"), openedAt: Date())
    }
}
/// Only the selected tab owns the push. Inactive stacks cannot dismiss another
/// stack's destination when SwiftUI updates their presentation bindings.
struct ClientRestoredDestination: ViewModifier {
    let tab: ClientTab
    @Environment(ClientNavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        let generation = navigation.restoredRouteGeneration
        let layout = navigation.stackGeneration
        return content.navigationDestination(isPresented: Binding(
            get: { navigation.destination == tab && navigation.restoredRoute != nil },
            set: { shown in
                if !shown, layout == navigation.stackGeneration, navigation.destination == tab {
                    navigation.dismissRestoredRoute(generation: generation)
                }
            }
        )) {
            if let route = navigation.restoredRoute {
                ClientRestoredRouteView(route: route)
            }
        }
    }
}
#endif
