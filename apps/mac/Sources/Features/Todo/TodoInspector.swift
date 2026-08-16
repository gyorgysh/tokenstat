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
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)?
    var onClose: () -> Void

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var baselineTitle = ""
    @State private var baselineNotes = ""
    @State private var saveState: FieldSaveState = .idle
    @FocusState private var focused: Field?
    @State private var loadedID: String?
    @State private var showDelegate = false
    @State private var backendID = ""
    @State private var modelChoice = ""
    @State private var effortChoice = ""
    @State private var workspaceID = ""
    @State private var budgetMinutes = "180"
    @State private var noTimeLimit = false
    @State private var applyingAgent = false
    @State private var starting = false

    private enum Field: Hashable { case title, notes }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                FeatureMark(
                    name: model.selectedCard?.isNote == true ? "mark_note" : "mark_todo",
                    tint: model.selectedCard?.isNote == true ? Theme.secondary : Theme.accent,
                    size: 16
                )
                .padding(.leading, Theme.Space.m)
                Text("Task")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Group {
                if let card = model.selectedCard {
                    cardBody(card)
                } else {
                    InspectorEmptyState(
                        mark: "mark_todo",
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
            let title = titleDraft
            let notes = notesDraft
            Task { await persistDrafts(for: old, title: title, notes: notes) }
            syncDrafts()
        }
        .onChange(of: focused) { _, new in
            if new == nil { Task { await persistDrafts() } }
        }
        .onChange(of: titleDraft) { _, _ in markDirtyIfNeeded() }
        .onChange(of: notesDraft) { _, _ in markDirtyIfNeeded() }
        .onDisappear { Task { await persistDrafts() } }
        .sheet(isPresented: $showDelegate) {
            if let card = model.selectedCard {
                DelegateSheet(
                    model: model,
                    card: card,
                    folders: folders,
                    onViewRun: onViewRun,
                    onRunInFront: onRunInFront
                )
            }
        }
    }

    private func cardBody(_ card: TodoCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($focused, equals: .title)
                    .onSubmit { Task { await persistDrafts() } }
                    .onAppear { syncDrafts() }

                notesEditor(card)

                FieldSaveBar(
                    state: saveState,
                    canSave: !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await persistDrafts() }
                } onCancel: {
                    titleDraft = baselineTitle
                    notesDraft = baselineNotes
                    saveState = .idle
                }

                labeled("Column", card.columnLabel)
                if !card.isNote {
                    agentFields(card)
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
                    Button("View run transcript") { onViewRun?(delegate.runId) }
                        .buttonStyle(AccentButtonStyle())
                }
                if !card.isNote, card.delegate?.isRunning != true {
                    if canRun {
                        TaskRunBar(
                            canRun: canRun,
                            running: starting
                        ) { placement in
                            Task { await startRun(card, inFront: placement == .front) }
                        }
                    } else {
                        Button("Run…") { showDelegate = true }
                            .buttonStyle(AccentButtonStyle())
                    }
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
    private func agentFields(_ card: TodoCard) -> some View {
        AppMenuPicker(
            title: "Agent",
            options: [(value: "", label: "Choose later")]
                + model.backends.map { (value: $0.id, label: $0.label) },
            selection: $backendID
        )
        .onChange(of: backendID) { old, new in
            guard !applyingAgent, old != new, loadedID == card.id else { return }
            modelChoice = ""
            effortChoice = ""
            Task { await persistAgent(card) }
        }
        AppMenuPicker(
            title: "Workspace",
            options: [(value: "", label: "Choose later")]
                + folders.map { (value: $0.id, label: $0.name) },
            selection: $workspaceID
        )
        .onChange(of: workspaceID) { _, _ in
            guard !applyingAgent, loadedID == card.id else { return }
            Task { await persistAgent(card) }
        }
        if let backend = model.backends.first(where: { $0.id == backendID }),
           !backend.models.isEmpty || !backend.efforts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !backend.models.isEmpty {
                    FavoriteModelPicker(
                        backendID: backend.id,
                        models: backend.models,
                        extra: modelChoice,
                        selection: $modelChoice
                    )
                    .onChange(of: modelChoice) { _, _ in
                        guard !applyingAgent, loadedID == card.id else { return }
                        Task { await persistAgent(card) }
                    }
                }
                if !backend.efforts.isEmpty {
                    AppMenuPicker(
                        title: "Effort",
                        options: [(value: "", label: "Default")]
                            + backend.efforts.map { (value: $0, label: $0) },
                        selection: $effortChoice
                    )
                    .onChange(of: effortChoice) { _, _ in
                        guard !applyingAgent, loadedID == card.id else { return }
                        Task { await persistAgent(card) }
                    }
                }
            }
        }
        HStack(spacing: Theme.Space.xs) {
            Text("Time limit")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("180", text: $budgetMinutes)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .disabled(noTimeLimit)
                .onSubmit { Task { await persistAgent(card) } }
            Text("minutes")
                .font(.caption)
                .foregroundStyle(.secondary)
            BrandToggleChip(title: "No limit", isOn: $noTimeLimit)
                .onChange(of: noTimeLimit) { _, _ in
                    guard !applyingAgent, loadedID == card.id else { return }
                    Task { await persistAgent(card) }
                }
        }
    }

    private var canRun: Bool {
        !backendID.isEmpty && !workspaceID.isEmpty
    }

    @ViewBuilder
    private func moveButtons(_ card: TodoCard) -> some View {
        HStack(spacing: Theme.Space.s) {
            if card.column != "backlog" {
                Button("Move to To Do") { Task { await model.move(card, to: "backlog") } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if card.column != "doing" {
                Button("Move to Doing") { Task { await model.move(card, to: "doing") } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if card.column != "done" {
                Button("Move to Done") { Task { await model.move(card, to: "done") } }
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
            saveState = .idle
            return
        }
        if loadedID == card.id { return }
        loadedID = card.id
        titleDraft = card.title
        notesDraft = card.notes
        baselineTitle = card.title
        baselineNotes = card.notes
        applyingAgent = true
        backendID = card.backend
        modelChoice = card.cleanedModel
        effortChoice = card.effort ?? ""
        workspaceID = card.workspaceID
        noTimeLimit = card.budgetSeconds == 0
        if card.budgetSeconds > 0 {
            budgetMinutes = String(max(1, card.budgetSeconds / 60))
        } else {
            budgetMinutes = "180"
        }
        saveState = .idle
        applyingAgent = false
        if (card.model ?? "") != card.cleanedModel {
            Task { await persistAgent(card) }
        }
    }

    private func persistAgent(_ card: TodoCard) async {
        let minutes = UInt64(budgetMinutes) ?? 180
        let budget: UInt64 = noTimeLimit ? 0 : minutes * 60
        let modelValue = TodoCard.cleanModelID(modelChoice)
        _ = await model.updateCard(
            card,
            backend: backendID,
            model: modelValue.isEmpty ? nil : modelValue,
            effort: effortChoice.isEmpty ? nil : effortChoice,
            workspaceID: workspaceID,
            budgetSeconds: budget
        )
    }

    private func startRun(_ card: TodoCard, inFront: Bool) async {
        if starting { return }
        starting = true
        await persistDrafts()
        await persistAgent(card)
        guard let latest = model.cards.first(where: { $0.id == card.id }) ?? model.selectedCard else {
            starting = false
            return
        }
        if inFront {
            onRunInFront?(InteractiveTaskLaunch(
                workspaceID: latest.workspaceID,
                backend: latest.backend,
                model: latest.cleanedModel.isEmpty ? nil : latest.cleanedModel,
                effort: latest.effort,
                prompt: latest.promptForRun,
                title: latest.title
            ))
            model.noticeOpenedInFront(latest.title)
            starting = false
            return
        }
        if let runID = await model.delegate(latest) {
            onViewRun?(runID)
        }
        starting = false
    }

    private func markDirtyIfNeeded() {
        guard loadedID != nil else { return }
        let dirty = titleDraft != baselineTitle || notesDraft != baselineNotes
        if dirty {
            if saveState != .saving { saveState = .dirty }
        } else if saveState == .dirty || saveState == .failed {
            saveState = .idle
        }
    }

    private func persistDrafts(
        for id: String? = nil,
        title: String? = nil,
        notes: String? = nil
    ) async {
        if saveState == .saving { return }
        let card: TodoCard?
        if let id {
            card = model.cards.first { $0.id == id }
        } else {
            card = model.selectedCard
        }
        guard let card else { return }
        let title = (title ?? titleDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes ?? notesDraft
        if title.isEmpty {
            titleDraft = baselineTitle
            if notes == baselineNotes {
                saveState = .idle
                return
            }
        }
        let titleChanged = !title.isEmpty && title != card.title
        let notesChanged = notes != card.notes
        guard titleChanged || notesChanged else {
            if saveState == .dirty { saveState = .idle }
            return
        }
        saveState = .saving
        var ok = true
        if titleChanged {
            ok = await model.updateTitle(card, title: title) && ok
        }
        if notesChanged {
            ok = await model.updateNotes(card, notes: notes) && ok
        }
        if ok {
            baselineTitle = title.isEmpty ? baselineTitle : title
            baselineNotes = notes
            saveState = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = .idle }
            }
        } else {
            saveState = .failed
        }
    }
}
