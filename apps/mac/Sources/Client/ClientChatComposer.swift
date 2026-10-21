// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import PhotosUI
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The bar under a phone transcript. Glass chrome, opaque field.
///
/// Drop still works from Files. Photos come from the picker, because a
/// screenshot on iOS lives in the pasteboard or the library, not on a Finder
/// thumbnail.
struct ClientChatComposer: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @Binding var draft: String
    var attachments: [ChatAttachment]
    var previews: [String: Data]
    var running: Bool
    /// A message typed now is read on the agent's next step, rather than
    /// waiting until the turn ends.
    var sendsAsNote: Bool = false
    var placeholder: String
    var onSend: () -> Void
    var onSendNow: () -> Void = {}
    var onStop: () -> Void
    var onKeyboardDidHide: () -> Void = {}
    var onAttach: (ChatInboxItem, WorkReference) async -> Void
    var onRemove: (ChatAttachment) -> Void
    var onOpenSetup: () -> Void
    var onImportURLs: ([URL], WorkReference) -> Void
    var onDropURLs: ([URL]) -> Void
    var onDropText: ([String]) -> Void
    var onDropData: ([Data]) -> Void
    var onDropTargeted: (Bool) -> Void

    @State private var importOwner: WorkReference?
    @State private var importing = false
    @State private var photoOwner: WorkReference?
    @State private var pickingPhotos = false
    @State private var urlDropTargeted = false
    @State private var textDropTargeted = false
    @State private var dataDropTargeted = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.isSharedSource { ChatSlashMenu(model: model) }
            ChatFileProgressNotice(model: model)
            if model.savedCopy != nil && !model.isSharedSource {
                Button(L10n.text("apple.clientchatcomposer.send_when_connected.c2aae57a"), .scheduled) { model.queueDraftWhenConnected() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.stagingAttachments > 0 || model.unconfirmedSend != nil || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty))
            }
            if model.selectedBackendMissing {
                ChatAgentAvailabilityNotice(model: model, chat: chat)
            }
            if model.draftSaveFailed {
                ChatDraftNotice(retrySave: { model.retryDraftSave() })
            } else if model.unconfirmedSend != nil, model.savedCopy != nil {
                Text(L10n.text("apple.clientchatcomposer.a_previous_send_needs_confirmation_return.825b7880"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else if let unconfirmed = model.unconfirmedSend {
                ChatDraftNotice(unconfirmed: unconfirmed,
                                checkAgain: { Task { await model.checkUnconfirmedSend() } })
            }
            ChatComposerControls(
                model: model,
                chat: chat,
                locked: setupLocked,
                compact: true
            ) {
                HStack(spacing: Theme.Space.s) {
                    // Show Hide only when the keyboard can be dismissed.
                    if focused {
                        Button(L10n.text("apple.clientchatcomposer.hide_keyboard.f6b0718e"), .hideKeyboard, action: hideKeyboard)
                            .modifier(ComposerChromeButton())
                            .transition(controlTransition)
                    }
                    // Stop stays here even when a queued draft enables Send.
                    if running {
                        Button(L10n.text("common.stop"), .stop, action: onStop)
                            .modifier(ComposerChromeButton())
                            .transition(controlTransition)
                    }
                    expandToggle
                }
            }
            if !attachments.isEmpty {
                strip
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                attachControl
                ChatFastModeButton(model: model, chat: chat, locked: setupLocked)
                field
                // The send button earns its 44 points only when there is
                // something to send. A permanently greyed one is a control
                // that has never done anything, taking the width a message
                // could have had.
                if canSend {
                    sendControl
                        .transition(controlTransition)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: canSend)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: running)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: expanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: focused)
        .padding(model.landingDraft == nil ? 12 : 0)
        .modifier(ClientComposerSurface(landing: model.landingDraft != nil))
        .dropDestination(for: String.self) { items, _ in
            onDropText(items)
            return !items.isEmpty
        } isTargeted: { targeted in
            textDropTargeted = targeted
            reportDropTarget()
        }
        .dropDestination(for: Data.self) { items, _ in
            onDropData(items)
            return !items.isEmpty
        } isTargeted: { targeted in
            dataDropTargeted = targeted
            reportDropTarget()
        }
        .dropDestination(for: URL.self) { items, _ in
            onDropURLs(items)
            return !items.isEmpty
        } isTargeted: { targeted in
            urlDropTargeted = targeted
            reportDropTarget()
        }
        .onChange(of: model.currentReference) { _, _ in
            importing = false; importOwner = nil; pickingPhotos = false; photoOwner = nil; photos = []
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, let owner = importOwner {
                onImportURLs(urls, owner)
            }
        }
        .photosPicker(
            isPresented: $pickingPhotos,
            selection: $photos,
            maxSelectionCount: 8,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photos) { _, items in
            guard !items.isEmpty, let owner = photoOwner else { return }
            photos = []
            Task { await ingest(photos: items, owner: owner) }
        }
        // Paste is offered from the attach menu. `onPasteCommand` is Mac-only.
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(attachments) { attachment in
                    ChatAttachmentTile(
                        attachment: attachment,
                        preview: previews[attachment.id],
                        unavailable: model.missingDraftAttachments.contains(attachment.id),
                        onRemove: { onRemove(attachment) }
                    )
                }
            }
        }
    }

    private var attachControl: some View {
        Menu {
            Button(L10n.text("apple.clientchatcomposer.choose_files.1157defa"), .attach) {
                importOwner = model.currentReference
                importing = true
            }
            Button(L10n.text("apple.clientchatcomposer.choose_photos.abc1dfd6"), .attach) {
                photoOwner = model.currentReference
                pickingPhotos = true
            }
            if ChatInbox.pasteboardHasAttachment() {
                Button(L10n.text("apple.clientchatcomposer.paste_from_clipboard.dc2d6f20"), .attach) {
                    ingest(items: ChatInbox.pasteboardItems())
                }
            }
        } label: {
            ActionIcon.attach.label(L10n.text("apple.clientchatcomposer.attach.d406ade2"))
                .environment(\.compactActions, true)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .disabled(model.landingDraft != nil && model.currentReference == nil)
        .accessibilityLabel(L10n.text("apple.clientchatcomposer.attach.d406ade2"))
    }

    /// Grow the writing area without leaving the conversation.
    ///
    /// Six lines is the right height for a message and the wrong one for a
    /// brief. The toggle sits at the top right of the bar, away from send, so
    /// the thumb that reaches for one never finds the other. The symbols are
    /// the same full-screen pair the rest of the app uses: the names this
    /// used to type by hand are not in SF Symbols, so the control worked
    /// and drew nothing.
    private var expandToggle: some View {
        Group {
            if expanded {
                Button(L10n.text("apple.clientchatcomposer.shrink_the_message_box.2430d33f"), .exitFullScreen) {
                    expanded = false
                }
            } else {
                Button(L10n.text("apple.clientchatcomposer.expand_the_message_box.c0441a94"), .enterFullScreen) {
                    expanded = true
                    focused = true
                }
            }
        }
        .modifier(ComposerChromeButton())
    }

    private var field: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(ClientType.body)
            .lineLimit(expanded ? 8...18 : 1...6)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: expanded ? 180 : 0, alignment: .topLeading)
            .focused($focused)
            .disabled(model.landingDraft?.isSubmitting == true)
            .padding(.vertical, 8)
            .submitLabel(model.isSharedSource ? .return : .send)
            .onSubmit { if canSend { sendTapped() } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                expanded = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                onKeyboardDidHide()
            }
    }

    private func hideKeyboard() {
        focused = false
        expanded = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func sendTapped() {
        hideKeyboard()
        onSend()
    }

    private func sendNowTapped() {
        hideKeyboard()
        onSendNow()
    }

    @ViewBuilder
    private var sendControl: some View {
        Button { sendTapped() } label: {
            ActionIcon.send.label(sendTitle).frame(width: 44, height: 44)
        }
        .modifier(ChatSendStyle())
        .environment(\.compactActions, true)
        .accessibilityLabel(sendsAsNote && model.selected?.nativeSteer != true ? L10n.text("apple.clientchatcomposer.add_a_note_for_the_next_step.4778177a") : sendTitle)
        .contextMenu {
            if running {
                Button(L10n.text("apple.clientchatcomposer.stop_and_send_now.8ad0a50d"), .send, action: sendNowTapped)
            }
        }
    }

    private var sendTitle: String {
        if let landing = model.landingDraft {
            return landing.isSubmitting ? L10n.text("common.new_chat.preparing")
                : (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                   ? L10n.text("common.new_chat.open_chat") : L10n.text("common.new_chat.send"))
        }
        if sendsAsNote && model.selected?.nativeSteer == true { return L10n.text("common.chat.steer") }
        if sendsAsNote { return L10n.text("apple.clientchatcomposer.next_step.298a9207") }
        return running ? L10n.text("apple.clientchatcomposer.send_after_this_turn.012fc8c3") : L10n.text("apple.clientchatcomposer.send.f6f4688f")
    }

    private var canSend: Bool { !cannotSend }

    /// Controls that come and go with what the bar can do right now.
    private var controlTransition: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }

    private var setupLocked: Bool { model.isSharedSource || running || (model.landingDraft != nil && !model.landingCanSubmit) }

    private var cannotSend: Bool {
        if model.isSharedSource { return true }
        if let landing = model.landingDraft { return !model.landingCanSubmit || landing.isSubmitting || landing.stagingAttachments > 0 }
        // A saved copy is read and drafted in, never sent from: the banner
        // above says why, and the field stays editable for those drafts.
        if model.canHandleChatCommandLocally && !model.sending && model.stagingAttachments == 0 && model.unconfirmedSend == nil { return false }
        return model.selectedBackendMissing || model.savedCopy != nil
            || model.stagingAttachments > 0
            || model.sending || model.unconfirmedSend != nil
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private var dropTargeted: Bool {
        urlDropTargeted || textDropTargeted || dataDropTargeted
    }

    private func reportDropTarget() {
        onDropTargeted(dropTargeted)
    }

    private func ingest(photos items: [PhotosPickerItem], owner: WorkReference) async {
        for picked in items {
            guard !Task.isCancelled, model.currentReference == owner,
                  WorkSessionContext.shared.scope == owner.scope else { return }
            do {
                guard let media = try await picked.loadTransferable(type: ChatPickedMedia.self) else { throw CocoaError(.fileReadUnknown) }
                defer { try? FileManager.default.removeItem(at: media.file.deletingLastPathComponent()) }
                guard !Task.isCancelled, model.currentReference == owner,
                      WorkSessionContext.shared.scope == owner.scope else { return }
                guard let item = ChatInbox.item(from: media.file) else { throw CocoaError(.fileReadUnknown) }
                await model.attach(item, to: owner)
            } catch {
                guard !Task.isCancelled, model.currentReference == owner,
                      WorkSessionContext.shared.scope == owner.scope else { return }
                model.error = L10n.text("common.chat_files_import_failed", picked.supportedContentTypes.first?.preferredFilenameExtension ?? "media")
                break
            }
        }
    }

    private func ingest(items: [ChatInboxItem]) {
        guard let owner = model.currentReference else { return }
        ingest(items: items, owner: owner)
    }

    private func ingest(items: [ChatInboxItem], owner: WorkReference) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                await onAttach(item, owner)
            }
        }
    }
}

/// The landing page already owns the surrounding card. Conversation bars
/// keep their ordinary floating surface and safe-area spacing.
private struct ClientComposerSurface: ViewModifier {
    let landing: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if landing { content }
        else {
            content.clientFloatingBar()
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.s)
        }
    }
}

private struct ChatSendStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(AccentButtonStyle(small: true))
        }
    }
}

/// A 44-point glyph in the composer chrome. Not a glass circle: that
/// style is for send, and using it for Stop grew the bar.
private struct ComposerChromeButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .environment(\.compactActions, true)
            // These glyphs occupy fixed touch targets; inherited accessibility
            // text sizes must not paint over the neighboring control.
            .font(Theme.fixed(18, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .layoutPriority(1)
    }
}

#endif

#if !os(macOS)
private struct ChatPickedMedia: Transferable {
    let file: URL
    private static func receive(_ received: ReceivedTransferredFile) throws -> ChatPickedMedia {
        let values = try received.file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, UInt64(size) <= ChatFileIO.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let destination = directory.appendingPathComponent(received.file.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: received.file, to: destination)
            try FileManager.default.setAttributes([.posixPermissions:0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            return ChatPickedMedia(file: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { value in SentTransferredFile(value.file) } importing: { try receive($0) }
        FileRepresentation(contentType: .image) { value in SentTransferredFile(value.file) } importing: { try receive($0) }
    }
}
#endif
