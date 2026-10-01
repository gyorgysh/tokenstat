// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import PhotosUI
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
            if model.savedCopy != nil {
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
            HStack(alignment: .top, spacing: Theme.Space.s) {
                ChatComposerControls(
                    model: model,
                    chat: chat,
                    locked: running,
                    compact: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                // Only while there is a keyboard to put away. A control that
                // cannot do anything is one the eye still has to read past
                // every time, and this row is already three controls wide on
                // a phone.
                if focused {
                    Button(L10n.text("apple.clientchatcomposer.hide_keyboard.f6b0718e"), .hideKeyboard, action: hideKeyboard)
                        .modifier(ComposerChromeButton())
                        .transition(controlTransition)
                }
                // Stay in this row whenever a turn is running. Parking it on
                // send, then jumping it up here the moment a queued draft
                // appears, grew the bar and put a glass circle where a
                // 44-point glyph belongs.
                if running {
                    Button(L10n.text("common.stop"), .stop, action: onStop)
                        .modifier(ComposerChromeButton())
                        .transition(controlTransition)
                }
                expandToggle
            }
            if !attachments.isEmpty {
                strip
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                attachControl
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: canSend)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: running)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: expanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: focused)
        .padding(12)
        .clientFloatingBar()
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.94))
                    .overlay {
                        Text(L10n.text("apple.clientchatcomposer.drop_to_attach.34a7a637"))
                            .font(ClientType.label.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .allowsHitTesting(false)
            }
        }
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropTargeted)
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
            matching: .images
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
            .frame(minHeight: expanded ? 180 : 0, alignment: .topLeading)
            .focused($focused)
            .padding(.vertical, 8)
            .submitLabel(.send)
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
        .accessibilityLabel(sendsAsNote ? L10n.text("apple.clientchatcomposer.add_a_note_for_the_next_step.4778177a") : sendTitle)
        .contextMenu {
            if running {
                Button(L10n.text("apple.clientchatcomposer.stop_and_send_now.8ad0a50d"), .send, action: sendNowTapped)
            }
        }
    }

    private var sendTitle: String {
        if sendsAsNote { return L10n.text("apple.clientchatcomposer.next_step.298a9207") }
        return running ? L10n.text("apple.clientchatcomposer.send_after_this_turn.012fc8c3") : L10n.text("apple.clientchatcomposer.send.f6f4688f")
    }

    private var canSend: Bool { !cannotSend }

    /// Controls that come and go with what the bar can do right now.
    private var controlTransition: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }

    private var cannotSend: Bool {
        // A saved copy is read and drafted in, never sent from: the banner
        // above says why, and the field stays editable for those drafts.
        model.selectedBackendMissing || model.savedCopy != nil
            || model.stagingAttachments > 0
            || model.sending
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private var dropTargeted: Bool {
        urlDropTargeted || textDropTargeted || dataDropTargeted
    }

    private func reportDropTarget() {
        onDropTargeted(dropTargeted)
    }

    private func ingest(photos items: [PhotosPickerItem], owner: WorkReference) async {
        var staged: [ChatInboxItem] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                continue
            }
            let type = item.supportedContentTypes.first ?? .png
            let name = "image.\(type.preferredFilenameExtension ?? "png")"
            staged.append(
                ChatInbox.prepared(
                    ChatInboxItem(data: data, name: name, mediaType: type.preferredMIMEType)
                )
            )
        }
        ingest(items: staged, owner: owner)
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
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .layoutPriority(1)
    }
}

#endif
