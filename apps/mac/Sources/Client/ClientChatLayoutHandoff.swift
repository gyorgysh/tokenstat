// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// A scene's logical chat survives presentation teardown. The lease is
/// acquired when the reader first appears, before a fold can remove it.
@MainActor
@Observable
final class ClientChatLayoutHandoff {
    struct Reader {
        let id: UUID
        let session: ClientChatSession
        let key: ClientChatSessions.Key
        let reference: WorkReference
        let folderName: String
        let hostName: String
        let presentationID: UUID?

        func matches(_ route: WorkMobileRoute) -> Bool {
            guard route.scope == reference.scope, let target = route.reference,
                  target.scope == reference.scope else { return false }
            return target == reference || (key.conversation == nil && target.kind == .workspace
                && target.hostIdentity == key.peer && target.workspaceID == key.workspace)
        }
    }

    struct Delivery {
        let id: UUID
        let reader: Reader
        let route: WorkMobileRoute
        let model: ChatModel
        let selection: UInt64
        let initiallyUnselected: Bool
        let intent: UInt64
    }

    private(set) var reader: Reader?
    private(set) var pending: Delivery?
    private(set) var intent: UInt64 = 0

    /// Presentation changes cannot replace another logical reader. A real
    /// navigation action clears that reader before its destination mounts.
    @discardableResult
    func show(session: ClientChatSession, key: ClientChatSessions.Key,
              reference: WorkReference, owner: UUID, folderName: String,
              hostName: String, presentationID: UUID?, intent: UInt64, handoffID: UUID?) -> Bool {
        guard intent == self.intent, reference.kind == .conversation, key.matches(reference) else { return false }
        guard session.model.selected == nil || session.model.selected?.id == reference.itemID else { return false }
        if let selected = session.model.currentReference {
            guard selected.scope == reference.scope, selected.hostIdentity == reference.hostIdentity,
                  selected.workspaceID == reference.workspaceID, selected.itemID == reference.itemID else { return false }
        }
        if let reader, !(reader.session === session && reader.key == key && reader.reference == reference) {
            return false
        }
        if let pending, pending.id != handoffID || !isCurrent(pending, scope: reference.scope) { return false }
        // Acquire the successor before acknowledging the old presentation.
        session.appear(owner)
        if reader == nil {
            let lease = UUID()
            session.appear(lease)
            reader = Reader(id: lease, session: session, key: key, reference: reference,
                folderName: folderName, hostName: hostName, presentationID: presentationID)
        }
        if let pending, pending.id == handoffID, pending.reader.session === session, pending.reader.key == key,
           pending.reader.reference == reference, isCurrent(pending, scope: reference.scope) {
            self.pending = nil
        }
        return true
    }

    /// Called only for user/system navigation, never show/leave callbacks.
    func navigate() {
        intent &+= 1
        pending = nil
        let previous = reader
        reader = nil
        if let previous { previous.session.disappear(previous.id) }
    }

    /// Latest, a row jump, or disclosure supersedes restoration while
    /// retaining the current chat as the logical destination.
    func chooseViewport(model: ChatModel) {
        guard reader?.session.model === model else { return }
        suspend()
    }

    /// A cover preserves the chat underneath it while retiring an unfinished
    /// layout delivery. Its reader has a separate session and cannot take over.
    func suspend() {
        intent &+= 1
        pending = nil
    }

    @discardableResult
    func begin(route: WorkMobileRoute) -> Delivery? {
        guard let reader, reader.reference == route.reference,
              reader.reference.scope == route.scope else { return nil }
        let model = reader.session.model
        guard model.selected == nil || model.selected?.id == reader.reference.itemID else { return nil }
        let delivery = Delivery(id: UUID(), reader: reader, route: route,
            model: model, selection: model.selectionGeneration,
            initiallyUnselected: model.selected == nil, intent: intent)
        pending = delivery
        return delivery
    }

    func isCurrent(_ delivery: Delivery, scope: WorkReference.Scope?) -> Bool {
        guard pending?.id == delivery.id, intent == delivery.intent,
              scope == delivery.route.scope, reader?.id == delivery.reader.id,
              delivery.reader.session.model === delivery.model else { return false }
        if let reference = delivery.model.currentReference {
            guard reference.scope == delivery.reader.reference.scope,
                  reference.hostIdentity == delivery.reader.reference.hostIdentity,
                  reference.workspaceID == delivery.reader.reference.workspaceID,
                  reference.itemID == delivery.reader.reference.itemID else { return false }
        }
        let sameSelection = delivery.model.selectionGeneration == delivery.selection
        // The first folder load, empty selection, and exact-chat opening each
        // advance generation. Before any selection there is no old viewport
        // to transfer; the same owner may finish that initial load sequence.
        let firstOpening = delivery.initiallyUnselected
            && (delivery.model.selected == nil || delivery.model.selected?.id == delivery.reader.reference.itemID)
        return (sameSelection || firstOpening)
            && (delivery.model.selected == nil || delivery.model.selected?.id == delivery.reader.reference.itemID)
    }

}

#if !os(macOS)
import SwiftUI

private struct ClientChatPresentationKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
private struct ClientChatHandoffKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var clientChatPresentationID: UUID? {
        get { self[ClientChatPresentationKey.self] }
        set { self[ClientChatPresentationKey.self] = newValue }
    }
    var clientChatHandoffID: UUID? {
        get { self[ClientChatHandoffKey.self] }
        set { self[ClientChatHandoffKey.self] = newValue }
    }
}

/// The root owns the destination snapshot after a row or lazy tile is gone.
struct ClientOwnedPush: Identifiable {
    let id: UUID
    let content: AnyView
}

/// Register the destination on the stable navigation root, preserving system
/// Back/swipe behavior without tying the presentation to a lazy tile or pin.
struct ClientOwnedNavigationLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.clientChatPresentationID) private var parentPresentationID
    @State private var presentationID = UUID()

    var body: some View {
        Button {
            navigation.pushOwned(ClientOwnedPush(id: presentationID,
                content: AnyView(destination().environment(\.clientChatPresentationID, presentationID))),
                from: parentPresentationID)
        } label: { label() }
    }
}

struct ClientOwnedPushDestination: ViewModifier {
    let tab: ClientTab
    var depth: Int = 0
    @Environment(ClientNavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        let generation = navigation.pushedChatGeneration
        let layout = navigation.stackGeneration
        return content.navigationDestination(isPresented: Binding(
            get: { navigation.destination == tab && navigation.pushedChats.indices.contains(depth) },
            set: { shown in
                if !shown, navigation.destination == tab {
                    navigation.dismissPushedChat(generation: generation, layout: layout, depth: depth)
                }
            }
        )) {
            if navigation.pushedChats.indices.contains(depth) {
                let push = navigation.pushedChats[depth]
                AnyView(push.content.id(push.id)
                    .modifier(ClientOwnedPushDestination(tab: tab, depth: depth + 1)))
            }
        }
    }
}
#endif
