// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TerminalPaneSelection.swift.

@main enum TerminalPaneSelectionTests {
    static func main() {
        let cli = "codex", ssh = "ssh:remote", secondSSH = "ssh:other"
        var selection = TerminalPaneSelection(selectedID: cli)
        selection.setSplit(true, available: [cli])
        precondition(selection.leadingID == cli && selection.trailingID == nil)

        // Connecting an SSH tab fills an empty split without moving the CLI.
        selection.select(ssh, available: [cli, ssh], split: true)
        precondition(selection.leadingID == cli && selection.trailingID == ssh)
        precondition(selection.selectedID == ssh)
        selection.select(cli, available: [cli, ssh], split: true)
        precondition(selection.leadingID == cli && selection.trailingID == ssh)

        // A new tab replaces the focused half, preserving the other transport.
        selection.select(ssh, available: [cli, ssh], split: true)
        selection.select(secondSSH, available: [cli, ssh, secondSSH], split: true)
        precondition(selection.leadingID == cli && selection.trailingID == secondSSH)

        // Closing an off-screen tab leaves the split alone; closing a visible
        // member collapses onto the surviving session and keeps focus valid.
        precondition(!selection.reconcile(available: [cli, secondSSH]))
        precondition(selection.reconcile(available: [secondSSH]))
        precondition(selection.selectedID == secondSSH)
        precondition(selection.leadingID == nil && selection.trailingID == nil)

        // Missing pins cannot show one emulator in both halves.
        selection = TerminalPaneSelection(selectedID: ssh, leadingID: "gone", trailingID: ssh)
        let panes = selection.panes(in: [ssh], split: true)
        precondition(panes.leading == ssh && panes.trailing == nil)

        // Open in split targets the unfocused half and keeps the current CLI.
        selection = TerminalPaneSelection(selectedID: cli, leadingID: cli, trailingID: ssh)
        selection.sendToOtherHalf(secondSSH, available: [cli, ssh, secondSSH])
        precondition(selection.leadingID == cli && selection.trailingID == secondSSH)
        precondition(selection.selectedID == cli)

        // Swapping a mixed split moves both panes, preserving the focused
        // session and leaving off-screen tabs out of the pair. Swapping again
        // restores their original positions.
        selection.swapPanes(available: [cli, ssh, secondSSH])
        precondition(selection.leadingID == secondSSH && selection.trailingID == cli)
        precondition(selection.selectedID == cli)
        selection.swapPanes(available: [cli, ssh, secondSSH])
        precondition(selection.leadingID == cli && selection.trailingID == secondSSH)
        precondition(selection.selectedID == cli)
        selection.select(secondSSH, available: [cli, ssh, secondSSH], split: true)
        selection.swapPanes(available: [cli, ssh, secondSSH])
        precondition(selection.leadingID == secondSSH && selection.trailingID == cli)
        precondition(selection.selectedID == secondSSH)

        // An empty or vanished half cannot be swapped into a duplicate pane.
        var incomplete = TerminalPaneSelection(selectedID: cli, leadingID: cli)
        incomplete.swapPanes(available: [cli, ssh])
        precondition(incomplete.leadingID == cli && incomplete.trailingID == nil)
        incomplete.trailingID = "gone"
        incomplete.swapPanes(available: [cli, ssh])
        precondition(incomplete.leadingID == cli && incomplete.trailingID == "gone")
        selection.select(cli, available: [cli, ssh, secondSSH], split: true)
        selection.setSplit(false, available: [cli, ssh, secondSSH])
        precondition(selection.selectedID == cli && selection.leadingID == nil && selection.trailingID == nil)
        precondition(!selection.reconcile(available: []))
        precondition(selection.selectedID == nil)
        print("Mixed terminal selection: SSH/CLI splits, swaps, focus, replacement, closing and missing pins passed")
    }
}
