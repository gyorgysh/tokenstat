// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

extension ChatModel {
    func confirmFileRelay(name: String, size: UInt64?, remaining: UInt64? = nil) async -> Bool {
        guard fileRelayAnswer == nil else { return false }
        let generation = selectionGeneration
        let approved = await withCheckedContinuation { answer in
            fileRelayName = name
            fileRelaySize = size
            fileRelayRemaining = remaining
            fileRelayAnswer = answer
        }
        return approved && generation == selectionGeneration && savedCopy == nil
    }
    func answerFileRelay(_ answer: Bool) {
        let continuation = fileRelayAnswer
        fileRelayAnswer = nil
        fileRelayName = nil
        continuation?.resume(returning: answer)
    }
    func updateFileProgress(_ progress: Double, name: String, reference: WorkReference, generation: UInt64? = nil, foreground: Bool = true) throws {
        guard currentReference == reference, WorkCacheAccess.canSave(reference), savedCopy == nil,
              generation == nil || generation == selectionGeneration else { throw CancellationError() }
        guard foreground else { return }
        guard !fileTransferCancelled else { throw CancellationError() }
        fileTransferProgress = progress
        fileTransferName = name
    }
}

struct ChatFileTransferControls: ViewModifier {
    @Bindable var model: ChatModel
    func body(content: Content) -> some View {
        content.modifier(ChatFileRelayConsent(model: model))
        .onChange(of: model.selectionGeneration) { _, _ in model.fileTransferCancelled = true; model.answerFileRelay(false) }
        .onDisappear { model.fileTransferCancelled = true; model.answerFileRelay(false) }
    }
}

/// Exactly one visible surface presents a transfer's consent request.
struct ChatFileRelayConsent: ViewModifier {
    @Bindable var model: ChatModel
    var presenter: UUID? = nil
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.fileRelayPresenter == presenter && model.fileRelayName != nil },
            set: { if !$0, model.fileRelayPresenter == presenter { model.answerFileRelay(false) } }
        )) {
            ChatFileRelaySheet(name: model.fileRelayName ?? "", size: model.fileRelaySize,
                remaining: model.fileRelayRemaining, answer: model.answerFileRelay)
        }
    }
}

private struct ChatFileRelaySheet: View {
    let name: String
    let size: UInt64?
    let remaining: UInt64?
    var answer: (Bool) -> Void
    @State private var usage: RelayUsage?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cancelButton: some View {
        Button(L10n.text("common.cancel"), role: .cancel) { answer(false) }
    }
    private var continueButton: some View {
        Button(L10n.text("common.continue")) { answer(true) }.buttonStyle(.borderedProminent)
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("common.chat_files_relay_title")).font(Theme.headline)
                    Text(L10n.text("common.chat_files_relay_explanation"))
                    HStack(alignment: .top) {
                        Image(systemName: "doc")
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(name).font(Theme.body.weight(.semibold)).lineLimit(3).truncationMode(.middle)
                            Text(size.map(RelayUsage.bytes) ?? L10n.text("common.chat_files_size_unknown"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if let usage, usage.isSupported {
                        Text(L10n.text("common.chat_files_relay_used", RelayUsage.bytes(usage.usedBytes), RelayUsage.bytes(usage.limitBytes)))
                            .font(Theme.body.weight(.semibold)).monospacedDigit()
                        ProgressView(value: usage.fraction)
                            .accessibilityLabel(L10n.text("common.chat_files_relay_usage_label"))
                        Text(L10n.text("common.chat_files_relay_available", RelayUsage.bytes(usage.remainingBytes)))
                            .monospacedDigit()
                        Text(L10n.text("common.chat_files_relay_allowance"))
                    } else {
                        if let remaining {
                            Text(L10n.text("common.chat_files_relay_available", RelayUsage.bytes(remaining)))
                        }
                        Text(L10n.text("common.chat_files_relay_usage_unknown"))
                    }
                    Text(L10n.text("common.chat_files_relay_reporting"))
                        .font(Theme.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) { cancelButton; continueButton }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack { cancelButton; Spacer(); continueButton }
            }
        }
        .font(Theme.body)
        .tint(Theme.accent)
        .padding(Theme.Space.l)
        #if os(macOS)
        .frame(width: 420, height: 510)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task {
            let scope = WorkSessionContext.shared.scope
            let generation = WorkSessionContext.shared.generation
            guard let account = try? await Bridge.account(), account.signedIn,
                  !Task.isCancelled, WorkSessionContext.shared.scope == scope,
                  WorkSessionContext.shared.generation == generation,
                  WorkReference.Scope.accountIdentity(handle: account.handle, id: account.accountId)
                    .flatMap({ WorkReference.Scope.account(origin: account.host, handle: $0) }) == scope
            else { return }
            usage = account.relayUsage
        }
    }
}

struct ChatFileProgressNotice: View {
    @Bindable var model: ChatModel
    var body: some View {
        if let name = model.fileTransferName {
            HStack(spacing: Theme.Space.s) {
                Text(name).lineLimit(1).truncationMode(.middle)
                ProgressView(value: model.fileTransferProgress).frame(maxWidth: 120)
                Text(model.fileTransferProgress, format: .percent.precision(.fractionLength(0)))
                Button(L10n.text("common.cancel"), .dismiss) { model.fileTransferCancelled = true; model.answerFileRelay(false) }
            }.font(Theme.caption).padding(Theme.Space.s)
        }
    }
}
