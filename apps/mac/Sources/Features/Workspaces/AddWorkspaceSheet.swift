// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

// Registering a folder means `NSOpenPanel`, so the whole sheet is macOS, the
// same way `WorkspacesModel.addFolder` behind it already is. A client has no
// folders of its own to add.
#if os(macOS)
import SwiftUI

/// The onboarding sheet behind "Add workspace…".
///
/// The decision is which folder. Everything else is two facts about that
/// choice: agents work there, and adding it does not upload it. The folder
/// panel still does the picking.
struct AddWorkspaceSheet: View {
    @Bindable var model: WorkspacesModel
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        ThemedSheet(
            title: "Add a workspace",
            subtitle: "Choose the project folder your agents should work in.",
            icon: .create,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Pick a repository you actually work in. It is the folder an agent opens, not your home directory and not a system folder.")
                    .font(Theme.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ModalInfoRow(
                        icon: .source,
                        title: "Agents work in this folder",
                        text: "They run as their own processes there. tokenstat reads git state so it can show changes, diffs and history."
                    )
                    ModalInfoRow(
                        icon: .security,
                        title: "Nothing is uploaded",
                        text: "Adding a workspace does not send the folder anywhere. Only usage counters are eligible for sync."
                    )
                }
            }
        } actions: {
            Button("Not now", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                picking = true
                Task {
                    await model.addFolder()
                    picking = false
                    dismiss()
                }
            } label: {
                ZStack {
                    ActionIcon.reveal.label("Choose folder…")
                        .opacity(picking ? 0 : 1)
                    if picking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(picking)
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 520, height: 380)
    }
}
#endif
