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
           let reference = route.reference, let place = place(reference) {
            ClientSavedPlaceView(place: place,
                restoredSection: reference.kind == .workspace
                    ? route.section.flatMap(WorkspaceSection.init(rawValue:)) : nil,
                onRestoredTerminalClose: reference.kind == .terminal
                    ? { navigation.restoredRoute = nil } : nil)
                .id(route)
        } else {
            ClientEmptyState(kind: .unreachable, title: "This place is unavailable",
                message: "Return to your workspaces to choose where to continue.")
                .padding(Theme.Space.m)
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
            workspaceName: "Workspace", openedAt: Date())
    }
}
/// Only the selected tab owns the push. Inactive stacks cannot dismiss another
/// stack's destination when SwiftUI updates their presentation bindings.
struct ClientRestoredDestination: ViewModifier {
    let tab: ClientTab
    @Environment(ClientNavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        let generation = navigation.restoredRouteGeneration
        return content.navigationDestination(isPresented: Binding(
            get: { navigation.destination == tab && navigation.restoredRoute != nil },
            set: { shown in
                if !shown, navigation.destination == tab {
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
