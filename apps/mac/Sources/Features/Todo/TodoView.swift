// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// A kanban board of work. A card is tracked here; delegating it hands it to an
/// agent on the chosen backend, and the run's transcript shows up in the
/// Automations screen.
struct TodoView: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]

    private static let columns: [(String, String)] = [
        ("backlog", "To Do"), ("doing", "Doing"), ("done", "Done"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(Theme.Space.m)
            }
            if let notice = model.noticeMessage {
                Banner(text: notice, severity: .success)
                    .padding(Theme.Space.m)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    ForEach(Self.columns, id: \.0) { id, label in
                        column(id, label)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        .navigationTitle("Todo")
        .task { await model.load() }
    }

    private func column(_ id: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionLabel(text: label, count: model.cards(in: id).count)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)

            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(model.cards(in: id)) { card in
                        CardView(model: model, card: card)
                    }
                    if model.cards(in: id).isEmpty {
                        Text(id == "done" ? "Nothing done yet" : "No cards")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if id == "backlog" {
                NewCardForm(model: model, folders: folders)
            }
        }
        .frame(width: 300)
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - One card

private struct CardView: View {
    @Bindable var model: TodoModel
    var card: TodoCard

    private var tint: Color {
        switch card.delegate?.status {
        case "running": return Theme.accent
        case "ok": return Theme.success
        case "error": return Theme.danger
        case "stopped": return Theme.warning
        default: return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(card.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer()
                if card.priority == "high" {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.warning)
                }
            }
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let delegate = card.delegate {
                delegateStatus(delegate)
            }
            HStack(spacing: Theme.Space.xs) {
                Text(model.backends.first { $0.id == card.backend }?.label ?? card.backend)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                controls
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(card.delegate == nil ? Theme.border : tint.opacity(0.4), lineWidth: 1)
        )
    }

    private func delegateStatus(_ delegate: TodoDelegate) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if delegate.isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(delegate.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            if let error = delegate.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
            if delegate.isRunning {
                Button("Stop") { Task { await model.stop(card) } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        Menu {
            if card.column != "backlog" {
                Button("Move to To Do") { Task { await model.move(card, to: "backlog") } }
            }
            if card.column != "doing" {
                Button("Move to Doing") { Task { await model.move(card, to: "doing") } }
            }
            if card.column != "done" {
                Button("Move to Done") { Task { await model.move(card, to: "done") } }
            }
            Divider()
            Button("Delegate to agent", systemImage: "paperplane") {
                Task { await model.delegate(card) }
            }
            Button("Delete", role: .destructive) { Task { await model.remove(card) } }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - New card

private struct NewCardForm: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]

    @State private var title = ""
    @State private var notes = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var budget = "900"
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                expanded.toggle()
            } label: {
                Label(expanded ? "New card" : "Add a card", systemImage: "plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)

            if expanded {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                HStack(spacing: Theme.Space.xs) {
                    Picker("", selection: $backendID) {
                        ForEach(model.backends) { backend in
                            Text(backend.label).tag(backend.id)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Picker("", selection: $workspaceID) {
                        Text("Folder").tag("")
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack {
                    TextField("Budget s", text: $budget)
                        .frame(width: 70)
                    Spacer()
                    Button("Add") {
                        Task {
                            await model.create(
                                title: title, notes: notes, backend: backendID,
                                workspaceID: workspaceID, budgetSeconds: UInt64(budget) ?? 900
                            )
                            title = ""
                            notes = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || workspaceID.isEmpty || backendID.isEmpty)
                }
            }
        }
        .onAppear {
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
        }
    }
}
