// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected task card. Thin on purpose: the board stays the overview.
struct TodoInspector: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]
    var onViewRun: ((String) -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                Text("Task")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, Theme.Space.m)
                Spacer(minLength: 0)
            }
            Group {
                if let card = model.selectedCard {
                    cardBody(card)
                } else {
                    InspectorEmptyState(
                        systemImage: "checklist",
                        title: "Pick a card",
                        subtitle: "Notes and delegate live here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private func cardBody(_ card: TodoCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                if !card.notes.isEmpty {
                    Text(card.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                labeled("Column", card.columnLabel)
                if !card.isNote {
                    labeled("Backend", model.backends.first { $0.id == card.backend }?.label ?? card.backend)
                    if let folder = folders.first(where: { $0.id == card.workspaceID }) {
                        labeled("Folder", folder.name)
                    }
                }
                if let delegate = card.delegate {
                    labeled("Run", delegate.label)
                    if delegate.isRunning {
                        Button("Stop") { Task { await model.stop(card) } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Open run") { onViewRun?(delegate.runId) }
                        .buttonStyle(AccentButtonStyle())
                } else if !card.isNote {
                    Button("Delegate to agent") { Task { await model.delegate(card) } }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
        }
    }
}
