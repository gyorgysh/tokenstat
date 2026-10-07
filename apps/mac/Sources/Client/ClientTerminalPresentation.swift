// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// The live terminal stays mounted while the workbench underneath rearranges.
struct ClientTerminalPresentation: ViewModifier {
    let model: ClientWorkspacesModel
    @Environment(AccountModel.self) private var account
    @State private var presented: ClientTerminalSession?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { model.activeTerminal },
            set: {
                if let next = $0 { model.activeTerminal = next }
                else if model.activeTerminal === presented { model.activeTerminal = nil }
            }
        )) { session in
            ClientTerminalScreen(session: session,
                hostName: model.hosts.first { $0.peerKey == session.peer }?.name ?? "",
                onClose: {
                    if model.activeTerminal === session { model.activeTerminal = nil }
                },
                onClosedProcess: {
                    guard model.connectedKey == session.peer else { return }
                    Task { await model.refresh(account: account.account) }
                })
                .onAppear {
                    if model.activeTerminal === session { presented = session }
                }
        }
    }
}
#endif
