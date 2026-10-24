// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamCommentComposer: View {
    @State private var model: TeamCommentModel
    let allowsComments: Bool
    /// False while the composer shows the agent instead. The model stays
    /// alive so a draft and a delivery check survive the switch.
    let visible: Bool
    let didPost: () -> Void
    let presentationChanged: (Bool, Bool) -> Void
    @Environment(\.teamCopy) private var copy
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @FocusState private var focused: Bool
    @State private var expandedEditor = false
    private var collapsed: Bool { allowsComments && textSize.isAccessibilitySize && !expandedEditor && !model.pending && model.text.isEmpty && !model.hasUnsavedWriting }

    init(store: TeamStore, context: TeamMutationContext, target: TeamCommentTarget, allowsComments: Bool, storage: TeamCommentDraftStore, location: TeamCommentLocation, visible: Bool = true, presentationChanged: @escaping (Bool, Bool) -> Void, didPost: @escaping () -> Void) {
        _model = State(initialValue: TeamCommentModel(target: target, store: store, context: context, storage: storage, location: location))
        self.allowsComments = allowsComments; self.visible = visible; self.didPost = didPost; self.presentationChanged = presentationChanged
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !visible {
                EmptyView()
            } else if collapsed {
                if let status = model.status { Text(status).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("team.comment.status") }
                Button(L10n.text("common.teams.write_comment"), .comment) { expandedEditor = true }
                    .buttonStyle(TeamButtonStyle(primary: true)).disabled(!model.loaded || !model.current).accessibilityIdentifier("team.comment.expand")
            } else if allowsComments || model.pending || !model.text.isEmpty {
                TeamComposerField(placeholder: L10n.text("common.teams.comment_placeholder"), text: Binding(get: { model.text }, set: { model.edit($0) }))
                    .disabled(!model.loaded || model.busy || model.pending || !allowsComments || !model.current)
                    .focused($focused).accessibilityIdentifier("team.comment.text")
                    .onAppear { if expandedEditor { focused = true } }
                if let error = model.error { Text(error).font(Theme.callout).foregroundStyle(TeamColors.warning).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("team.comment.error") }
                if model.error == nil, let status = model.status { Text(status).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("team.comment.status") }
                if model.tooLong { Text(L10n.text("common.teams.comment_too_long")).font(Theme.callout).foregroundStyle(TeamColors.warning).fixedSize(horizontal: false, vertical: true) }
                actions
                if model.hasUnsavedWriting {
                    if let recovered = model.recoveredText {
                        Text(L10n.text("common.teams.unsaved_comment_copy")).font(Theme.caption.weight(.semibold))
                        Text(recovered).font(Theme.body).lineLimit(6).textSelection(.enabled)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Button(model.recoveredText == nil ? L10n.text("common.teams.copy_draft") : L10n.text("common.teams.copy_unsaved_text"), .copy) { copy(model.copyText) }.buttonStyle(TeamComposerButtonStyle())
                        Button(L10n.text("common.teams.load_saved_draft"), .refresh) { Task { await model.reloadSavedDraft() } }.buttonStyle(TeamComposerButtonStyle()).disabled(model.pending || model.busy)
                    }
                }
                if !model.loaded {
                    Button(L10n.text("common.retry"), .refresh) { Task { await model.restore() } }.buttonStyle(TeamComposerButtonStyle())
                }
            } else if !model.loaded, model.error != nil {
                TeamNotice(message: L10n.text("common.teams.comment_save_failed"), warning: true)
            }
        }
        .task { await model.restore() }
        .onDisappear { model.saveOnLeave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveOnLeave() } }
        .onChange(of: model.acceptedRevision) { _, _ in expandedEditor = false; focused = false; didPost() }
        .onChange(of: focused) { _, _ in presentationChanged(focused, model.pending) }
        .onChange(of: model.pending, initial: true) { _, _ in presentationChanged(focused, model.pending) }
    }
    private var audience: some View {
        Text(L10n.text("common.teams.comment_audience")).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
    }
    /// Who reads it on the leading side, the buttons on the trailing side,
    /// the way the main composer's utility row is laid out.
    @ViewBuilder
    private var actions: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: Theme.Space.s) { if !model.pending { audience }; buttons }.frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { if !model.pending { audience }; Spacer(minLength: Theme.Space.m); buttons }
                VStack(alignment: .leading, spacing: Theme.Space.s) { if !model.pending { audience }; HStack(spacing: Theme.Space.s) { Spacer(minLength: 0); buttons } }
            }
        }
    }
    @ViewBuilder private var buttons: some View {
        if model.busy { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
        #if os(iOS)
        if focused { ClientKeyboardDismissButton() }
        #endif
        if model.pending {
            Button(L10n.text("common.teams.copy_draft"), .copy) { copy(model.text) }.buttonStyle(TeamComposerButtonStyle())
            Button(L10n.text("common.teams.check_delivery"), .refresh) { Task { await model.checkDelivery() } }.buttonStyle(TeamComposerButtonStyle()).disabled(model.busy || !model.current).accessibilityIdentifier("team.comment.check")
        }
        if allowsComments {
            Button(model.pending ? L10n.text("common.teams.send_same_comment") : L10n.text("common.teams.post_comment"), .send) { focused = false; Task { await model.send() } }
                .buttonStyle(TeamComposerButtonStyle(primary: true))
                .help(L10n.text("common.teams.post_comment")).disabled(!model.canSend).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("team.comment.send")
        }
    }
}
