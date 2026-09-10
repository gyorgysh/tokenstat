// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Only the conversation in front asks its own host about shared work.
/// An offer is a doorway to review, never an automatic draft or scroll change.
struct WorkHandoffOffer: View {
    @Bindable var chat: ChatModel
    let onOpen: () -> Void
    @Environment(AccountModel.self) private var account
    @State private var offered: WorkHandoff?
    @State private var dismissedRequest: String?
    @State private var connection: WorkHandoffConnection?

    var body: some View {
        Group {
            if let offered, offered.requestID != dismissedRequest,
               connection?.isCurrent == true {
                HStack(spacing: Theme.Space.s) {
                    Button("Continue from \(offered.deviceName)", .device) {
                        dismissedRequest = offered.requestID
                        onOpen()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                    InspectorCloseButton(action: { dismissedRequest = offered.requestID },
                        help: "Keep working here", label: "Dismiss shared work offer")
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.sidebar)
            }
        }
        .task(id: chat.readingIdentity) {
            offered = nil
            let peer = chat.peer
            guard let connection = WorkHandoffConnection(chat: chat, hostIsLinked: {
                account.account?.signedIn == true
                    && account.account?.machines.contains(where: { $0.publicIdentity == peer }) == true
            }) else { return }
            self.connection = connection
            let model = connection.makeModel()
            await model.load()
            guard connection.isCurrent, let record = model.shared else { return }
            // The authenticated identity, not the device's editable label,
            // decides whether this came from somewhere else.
            guard let identity = try? await Bridge.machineIdentity(),
                  connection.isCurrent, record.deviceID != identity.key else { return }
            offered = record
        }
    }
}
