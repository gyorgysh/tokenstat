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
        content.alert(L10n.text("common.chat_files_relay_title"), isPresented: Binding(
            get: { model.fileRelayPresenter == presenter && model.fileRelayName != nil },
            set: { if !$0, model.fileRelayPresenter == presenter { model.answerFileRelay(false) } }
        )) {
            Button(L10n.text("common.cancel"), role: .cancel) { model.answerFileRelay(false) }
            Button(L10n.text("common.continue")) { model.answerFileRelay(true) }
        } message: {
            Text(L10n.text("common.chat_files_relay_message", model.fileRelayName ?? "",
                ByteCountFormatter.string(fromByteCount: Int64(clamping: model.fileRelaySize ?? 0), countStyle: .file)))
            if let remaining = model.fileRelayRemaining { Text(L10n.text("common.chat_files_remaining", ByteCountFormatter.string(fromByteCount: Int64(clamping: remaining), countStyle: .file))) }
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
