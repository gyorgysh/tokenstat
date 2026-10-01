// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Desktop and mobile share the durable editor and explicit checked save.
/// Selection replaces the presentation; its scoped session keeps the writing.
struct TodoInspector: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]
    var onViewRun: ((String, String) -> Void)?
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)?
    var onOpenTerminal: ((PtySessionInfo) -> Void)?
    var onReviewWorkspace: ((String, TaskResultWorkspaceSurface) -> Void)? = nil
    var onClose: () -> Void
    @State private var runCard: TodoCard?

    var body: some View {
        VStack(spacing: 0) {
            if let card = model.selectedCard, !card.isNote {
                TaskEditorDestination(target: TaskEditorTarget(peer: nil), card: card, hostName: "This computer",
                                      onSaved: { await model.load() }, onClose: onClose,
                                      onViewRun: onViewRun, onOpenTerminal: onOpenTerminal,
                                      onReviewWorkspace: onReviewWorkspace)
                    .id(card.id)
                ThemeRule()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(card.columnLabel).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        Spacer()
                        Menu {
                            ForEach([("backlog", L10n.text("apple.todoinspector.to_do.150d92c4")), ("doing", L10n.text("apple.todoinspector.doing.cd742c53")), ("done", L10n.text("common.done")), ("archive", L10n.text("common.archive"))], id: \.0) { column, title in
                                if card.column != column {
                                    Button(title, .move) { Task { await model.move(card, to: column) } }
                                }
                            }
                        } label: { ActionLabel(title: L10n.text("apple.todoinspector.move.6ecc3df6"), icon: .move) }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if let delegate = card.delegate {
                        Text(delegate.label).font(Theme.callout)
                        if let error = delegate.error, !error.isEmpty {
                            Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(3)
                        }
                        HStack {
                            if delegate.isRunning {
                                Button(L10n.text("common.stop"), .stop) { Task { await model.stop(card) } }.buttonStyle(SecondaryButtonStyle())
                            }
                            Button(L10n.text("apple.todoinspector.view_run.aaf7fccc"), .preview) { onViewRun?(delegate.runId, card.workspaceID) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }.padding(Theme.Space.m)
            } else {
                InspectorChromeBar(onClose: onClose) {
                    InspectorTitle(title: L10n.text("apple.todoinspector.task.4bc74b21"), symbol: "checklist")
                    Spacer(minLength: 0)
                }
                InspectorEmptyState(mark: "mark_todo", title: L10n.text("apple.todoinspector.pick_a_task.dab569d2"), subtitle: L10n.text("apple.todoinspector.edit_its_prompt_settings_and_run_here.459576ae"))
            }
        }
        .background(Theme.background)
        .sheet(item: $runCard) { card in
            DelegateSheet(model: model, card: card, folders: folders, onViewRun: onViewRun, onRunInFront: onRunInFront)
        }
    }
}
