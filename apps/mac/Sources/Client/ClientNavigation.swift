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
}

#endif
