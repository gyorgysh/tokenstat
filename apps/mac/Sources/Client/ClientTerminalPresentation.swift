// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// The live terminal stays mounted while the workbench underneath rearranges.
struct ClientTerminalPresentation: ViewModifier {
    let model: ClientWorkspacesModel
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @State private var presented: ClientTerminalSession?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { model.activeTerminal },
            set: {
                if let next = $0 { model.activeTerminal = next }
                else if model.activeTerminal === presented {
                    if let presented { navigation.leaveTerminal(owner: presented.id) }
                    model.activeTerminal = nil
                }
            }
        )) { session in
            ClientTerminalScreen(session: session,
                hostName: model.hosts.first { $0.peerKey == session.peer }?.name ?? "",
                onClose: {
                    if model.activeTerminal === session {
                        navigation.leaveTerminal(owner: session.id)
                        model.activeTerminal = nil
                    }
                },
                onClosedProcess: {
                    guard model.connectedKey == session.peer else { return }
                    Task { await model.refresh(account: account.account) }
                })
                .onAppear {
                    if model.activeTerminal === session { presented = session }
                }
        }
        .onChange(of: model.activeTerminal?.id) { previous, current in
            if let previous, previous != current { navigation.leaveTerminal(owner: previous) }
        }
    }
}
#endif
