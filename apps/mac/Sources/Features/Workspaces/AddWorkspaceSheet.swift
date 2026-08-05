// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The onboarding sheet behind "Add workspace…".
///
/// A bare folder picker does not say what a workspace is, so a first-time user
/// guesses and usually guesses wrong (home directory, a system folder, a file
/// manager they cannot open). This explains the three things that matter —
/// what it is, what to pick, what happens next — and only then offers the
/// folder panel.
struct AddWorkspaceSheet: View {
    @Bindable var model: WorkspacesModel
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a workspace")
                        .font(.title3.weight(.semibold))
                    Text("A workspace is where your agents work")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            step(
                number: 1,
                title: "What it is",
                text: "A workspace is a project folder on this Mac. tokenstat runs agents there — Claude Code, Codex, OpenCode, Grok Build and the rest — and reads the folder's git state so it can show changes, diffs and history."
            )
            step(
                number: 2,
                title: "What to pick",
                text: "Choose a repository you actually work in — the folder an agent should open when it does work for you. Not your home directory, and not a system folder."
            )
            step(
                number: 3,
                title: "What happens next",
                text: "You can open files, browse the folder, and launch any installed agent in it. The agents run as their own processes, and only usage counters ever leave the machine."
            )

            Spacer(minLength: Theme.Space.m)

            HStack(spacing: Theme.Space.s) {
                Button("Not now") { dismiss() }
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    picking = true
                    Task {
                        await model.addFolder()
                        // Added or cancelled, the sheet's job is done: the
                        // explanation was seen and the panel answered.
                        picking = false
                        dismiss()
                    }
                } label: {
                    if picking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Choose folder…", systemImage: "folder")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(picking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 460, height: 380)
    }

    private func step(
        number: Int,
        title: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(number)")
                .font(Theme.numeric(13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
