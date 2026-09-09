// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Where the person is, held above the layout rather than inside it.
///
/// The client can be drawn two ways (see `ClientLayoutMode`), and detaching a
/// keyboard swaps between them. The selection cannot live inside either shape
/// or the swap lands you on Home, which is the one thing that would make the
/// feature feel like a bug.
///
/// **What survives a swap is the destination and the selected folder**, not a
/// pushed stack. Each tab's `NavigationStack` owns its own pushes and there is
/// no honest way to replay a view-based push into a split view's detail column,
/// so this does not pretend to. Landing on the folder you were in, in the other
/// shape, is the promise.
@MainActor
@Observable
final class ClientNavigationModel {
    /// The destination: a tab in tab mode, a sidebar row in sidebar mode.
    var destination: ClientTab = .home

    /// The folder open in the workspace plane, as `remote:<peer>:<id>`.
    var folderID: String?

    /// Which of that folder's sections is showing. The sidebar lists them, so
    /// the detail column draws one section rather than the sections again.
    var section: WorkspaceSection = .sessions

    /// Conversation a notification asked to open, consumed by the chat list
    /// once that folder is on screen.
    var openChatID: String?

    /// The conversation the person is already in, as the folder thread or a
    /// Recents push. A notification tap for this id leaves that window as it
    /// is: locking the phone does not unmount it, and remounting blanks the
    /// transcript. The cover a tap presents is `presentedChat`, not this.
    var visibleChatID: String?

    /// A chat opened from a notification on the tab layout, where there is
    /// no sidebar to land the folder in. Dismissing it returns where you were.
    var presentedChat: PresentedChat?

    /// True when this conversation is already on screen, so a tap should not
    /// open it again.
    func isShowing(chatID: String) -> Bool {
        guard !chatID.isEmpty else { return false }
        return presentedChat?.chatID == chatID || visibleChatID == chatID
    }

    /// A first task, offered to the composer of the next chat that opens.
    ///
    /// Text, never a sent message. Setup ends by handing somebody a project and
    /// something to type into it, and a prompt may cost money, so the send stays
    /// theirs. Consumed once by the chat that picks it up: coming back to that
    /// folder later must not refill an emptied composer.
    var suggestedPrompt: String?

    /// Take the offered first task, if there is one. Reading it clears it.
    func takeSuggestedPrompt() -> String? {
        defer { suggestedPrompt = nil }
        return suggestedPrompt
    }

    /// The machine Devices should be showing, when something outside that tab
    /// asked for it.
    ///
    /// A machine id rather than a `Machine`, because the account list is
    /// reloaded underneath and the row that opened this may not be the same
    /// value by the time the push happens. `ClientDevicesView` clears it when
    /// the push ends, so returning to Devices later lands on the list.
    var deviceMachineID: String?

    /// Selecting a folder implies the workspace plane, so both move together.
    func open(folderID: String?, section: WorkspaceSection = .sessions) {
        self.folderID = folderID
        self.section = section
        if folderID != nil { destination = .workspaces }
    }

    /// Folders pushed on the Workspaces tab's stack. `folderID` alone cannot
    /// do this: the tab layout observes the destination but not the folder,
    /// so a push needs its own road.
    var workspacesPath: [ClientFolderPush] = []

    /// Open a folder's section as a push on the Workspaces tab. New chat
    /// lands in that folder's chat, new session in its launcher.
    func pushFolder(peerKey: String, hostName: String, folder: WorkspaceFolder, section: WorkspaceSection) {
        workspacesPath.append(ClientFolderPush(peerKey: peerKey, hostName: hostName, folder: folder, section: section))
        destination = .workspaces
    }

    /// Show one machine on Devices, from anywhere.
    ///
    /// Workspaces lists the same computers it can reach, and the readings on
    /// that row are a summary of a screen that already exists. Tapping the row
    /// goes there rather than growing a second device screen inside
    /// Workspaces.
    func openDevice(machineID: String?) {
        guard let machineID, !machineID.isEmpty else { return }
        deviceMachineID = machineID
        destination = .machines
    }

    /// Open this conversation in its folder's chat section.
    ///
    /// If that thread is already the one on screen, only the destination
    /// moves. Setting `openChatID` again would re-select it and blank the
    /// transcript.
    func openChat(folderID: String, chatID: String) {
        guard !folderID.isEmpty, !chatID.isEmpty else { return }
        let already = self.folderID == folderID && section == .chat && isShowing(chatID: chatID)
        self.folderID = folderID
        self.section = .chat
        self.destination = .workspaces
        if already { return }
        self.openChatID = chatID
    }
}

/// One folder's section, pushed on the Workspaces tab's stack.
struct ClientFolderPush: Hashable {
    let peerKey: String
    let hostName: String
    let folder: WorkspaceFolder
    let section: WorkspaceSection

    @ViewBuilder
    var destination: some View {
        switch section {
        case .chat:
            ClientChatView(
                peer: peerKey,
                workspaceID: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id,
                folderName: folder.name,
                hostName: hostName
            )
        case .sessions:
            ClientWorkspaceSessionsView(peer: peerKey, hostName: hostName, folder: folder)
        default:
            ClientWorkspaceDetailView(peer: peerKey, hostName: hostName, folder: folder)
        }
    }
}

/// Enough to open one thread from a notification without keeping a folder
/// model around. The ids are host-local and arrived over the tunnel, not
/// on the push.
struct PresentedChat: Identifiable, Equatable {
    var id: String { "\(peer)/\(chatID)" }
    var peer: String
    var workspaceID: String
    var folderName: String
    var hostName: String
    var chatID: String
}

#endif
