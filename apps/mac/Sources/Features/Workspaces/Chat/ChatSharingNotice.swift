// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The original personal reader keeps its own draft and history. Team work
/// has a separate audience and can never inherit this composer's writing.
struct ChatSharingNotice: View {
    @Bindable var model: ChatModel
    #if os(macOS)
    @State private var recovery: ChatSharingRecoveryTarget?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: ActionIcon.team.symbol).font(Theme.headline).accessibilityHidden(true)
                Text(L10n.text("common.teams.shared_chat")).font(Theme.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("common.teams.private_source_notice"))
                .font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            if model.peer == nil, model.savedCopy == nil {
                Button(L10n.text("common.teams.manage_sharing"), .team) {
                    guard let reference = model.currentReference, let marker = model.selected?.teamShare else { return }
                    recovery = .init(reference: reference, selection: model.selectionGeneration,
                                     session: WorkSessionContext.shared.generation, share: marker.id)
                }
                .buttonStyle(TeamButtonStyle())
                .accessibilityIdentifier("chat.sharing.manage")
            } else {
                Text(L10n.text("common.teams.recover_on_publisher"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #else
            Text(L10n.text("common.teams.recover_on_publisher"))
                .font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.sharing.notice")
        #if os(macOS)
        .sheet(item: $recovery) { target in ChatSharingRecoverySheet(model: model, target: target) }
        .onChange(of: model.currentReference) { recovery = nil }
        #endif
    }
}

#if os(macOS)
private struct ChatSharingRecoveryTarget: Identifiable {
    let id = UUID()
    let reference: WorkReference
    let selection: UInt64
    let session: UInt64
    let share: String
}

private struct ChatSharingRecoverySheet: View {
    @Bindable var model: ChatModel
    let target: ChatSharingRecoveryTarget
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: ChatLocalSharingInfo.Sharing?
    @State private var loading = false
    @State private var stopping = false
    @State private var error: String?
    @State private var stopped: ChatLocalSharingStopped?

    private var isCurrent: Bool {
        model.peer == nil && model.savedCopy == nil && model.currentReference == target.reference
            && model.selectionGeneration == target.selection
            && WorkSessionContext.shared.generation == target.session
            && WorkSessionContext.shared.scope == target.reference.scope
    }

    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.stop_sharing_chat"), subtitle: L10n.text("common.teams.this_computer"), icon: .team, scrolls: true,
                    onClose: { if !stopping { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if !isCurrent { TeamNotice(message: L10n.text("common.teams.checkout_access_changed"), warning: true) }
                else if let stopped {
                    TeamNotice(message: L10n.text(stopped.accountCleanupPending ? "common.teams.cleanup_pending" : "common.teams.sharing_stopped"))
                    if !stopped.privateReady { TeamNotice(message: L10n.text("common.teams.local_recovery_retry"), warning: true) }
                } else {
                    Text(L10n.text("common.teams.local_stop_explanation"))
                        .font(Theme.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if sharing?.sourceOnly == true {
                        TeamNotice(message: L10n.text("common.teams.local_record_unavailable"), warning: true)
                    }
                }
                if let error { TeamNotice(message: error, warning: true) }
                if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            }
        } actions: {
            Button(L10n.text("common.close"), .dismiss) { dismiss() }
                .buttonStyle(TeamButtonStyle()).disabled(stopping).keyboardShortcut(.cancelAction)
            Spacer(minLength: Theme.Space.m)
            if stopping { ProgressView().controlSize(.small) }
            if isCurrent, stopped?.privateReady != true {
                if error != nil {
                    Button(L10n.text("common.retry"), .refresh) { Task { await load() } }
                        .buttonStyle(TeamButtonStyle()).disabled(loading || stopping)
                }
                Button(L10n.text("common.teams.stop_sharing"), .revoke, role: .destructive) { Task { await stop() } }
                    .buttonStyle(TeamButtonStyle(primary: true))
                    .disabled(sharing == nil || loading || stopping || error != nil)
                    .accessibilityIdentifier("chat.sharing.stop_local")
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(stopping)
    }

    private func load() async {
        guard isCurrent, !loading, !stopping, let id = target.reference.itemID else { return }
        loading = true; error = nil; sharing = nil
        defer { loading = false }
        do {
            let result = try await Bridge.localChatSharing(workspaceID: target.reference.workspaceID, id: id,
                scope: target.reference.scope, generation: target.session)
            guard isCurrent else { return }
            guard let row = result.sharing, row.id == target.share else {
                await model.refreshSharingSource(reference: target.reference, generation: target.selection)
                dismiss(); return
            }
            sharing = row
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }

    private func stop() async {
        guard isCurrent, let sharing, sharing.id == target.share, !loading, !stopping,
              let id = target.reference.itemID else { return }
        stopping = true; error = nil
        defer { stopping = false }
        do {
            let result = try await Bridge.stopLocalChatSharing(workspaceID: target.reference.workspaceID, id: id,
                sharing: sharing, scope: target.reference.scope, generation: target.session)
            guard isCurrent, result.stoppedLocally else { return }
            stopped = result
            if result.privateReady {
                let message: String
                if sharing.sourceOnly == true { message = L10n.text("common.teams.local_reference_remaining") }
                else if result.accountCleanupPending { message = L10n.text("common.teams.cleanup_pending") }
                else { message = L10n.text("common.teams.sharing_stopped") }
                await model.refreshSharingSource(reference: target.reference, generation: target.selection, notice: message)
            }
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
}
#endif
