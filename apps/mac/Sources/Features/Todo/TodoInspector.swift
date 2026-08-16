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

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @FocusState private var focused: Field?
    @State private var loadedID: String?

    private enum Field: Hashable { case title, notes }

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
        .onChange(of: model.selectedCardID) { old, _ in
            saveDrafts(for: old)
            syncDrafts()
        }
        .onChange(of: focused) { _, new in
            if new == nil { saveDrafts() }
        }
        .onDisappear { saveDrafts() }
    }

    private func cardBody(_ card: TodoCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($focused, equals: .title)
                    .onSubmit { saveDrafts() }
                    .onAppear { syncDrafts() }

                notesEditor(card)

                labeled("Column", card.columnLabel)
                if !card.isNote {
                    labeled(
                        "Backend",
                        model.backends.first { $0.id == card.backend }?.label ?? card.backend
                    )
                    if let modelName = card.model, !modelName.isEmpty {
                        labeled("Model", modelName)
                    }
                    if let folder = folders.first(where: { $0.id == card.workspaceID }) {
                        labeled("Folder", folder.name)
                    }
                }

                if let delegate = card.delegate {
                    labeled("Run", delegate.label)
                    if let error = delegate.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

                moveButtons(card)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notesEditor(_ card: TodoCard) -> some View {
        let prompt: String = {
            if card.isNote { return "Note" }
            return card.backend == "sh" ? "Command" : "Prompt"
        }()
        return TextEditor(text: $notesDraft)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 72, maxHeight: 140)
            .padding(Theme.Space.xs)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if notesDraft.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.s)
                        .allowsHitTesting(false)
                }
            }
            .focused($focused, equals: .notes)
    }

    @ViewBuilder
    private func moveButtons(_ card: TodoCard) -> some View {
        HStack(spacing: Theme.Space.s) {
            if card.column != "backlog" {
                Button("To Do") { Task { await model.move(card, to: "backlog") } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if card.column != "doing" {
                Button("Doing") { Task { await model.move(card, to: "doing") } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if card.column != "done" {
                Button("Done") { Task { await model.move(card, to: "done") } }
                    .buttonStyle(SecondaryButtonStyle())
            }
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

    private func syncDrafts() {
        guard let card = model.selectedCard else {
            loadedID = nil
            return
        }
        if loadedID == card.id { return }
        loadedID = card.id
        titleDraft = card.title
        notesDraft = card.notes
    }

    private func saveDrafts(for id: String? = nil) {
        let card: TodoCard?
        if let id {
            card = model.cards.first { $0.id == id }
        } else {
            card = model.selectedCard
        }
        guard let card else { return }
        let title = titleDraft
        let notes = notesDraft
        Task {
            if title != card.title {
                await model.updateTitle(card, title: title)
            }
            if notes != card.notes {
                await model.updateNotes(card, notes: notes)
            }
        }
    }
}
