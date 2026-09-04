// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import PhotosUI
import SwiftUI
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
    var placeholder: String
    var onSend: () -> Void
    var onStop: () -> Void
    var onAttach: (ChatInboxItem) async -> Void
    var onRemove: (ChatAttachment) -> Void
    var onOpenSetup: () -> Void
    var onDropURLs: ([URL]) -> Void
    var onDropText: ([String]) -> Void
    var onDropData: ([Data]) -> Void
    var onDropTargeted: (Bool) -> Void

    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var urlDropTargeted = false
    @State private var textDropTargeted = false
    @State private var dataDropTargeted = false
    @State private var photos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ChatComposerControls(
                model: model,
                chat: chat,
                locked: running
            )
            if !attachments.isEmpty {
                strip
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                attachControl
                field
                if running {
                    Button("Stop", .stop) { onStop() }
                        .clientGlassStyle()
                        .environment(\.compactActions, true)
                } else {
                    Button("Send", .send) { onSend() }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .disabled(cannotSend)
                }
            }
        }
        .padding(12)
        .clientFloatingBar()
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.94))
                    .overlay {
                        Text("Drop to attach")
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
        .animation(.easeOut(duration: 0.16), value: dropTargeted)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                onDropURLs(urls)
            }
        }
        .photosPicker(
            isPresented: $pickingPhotos,
            selection: $photos,
            maxSelectionCount: 8,
            matching: .images
        )
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task { await ingest(photos: items) }
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
                        onRemove: { onRemove(attachment) }
                    )
                }
            }
        }
    }

    private var attachControl: some View {
        Menu {
            Button("Choose files", .attach) { importing = true }
            Button("Choose photos", .attach) { pickingPhotos = true }
            if ChatInbox.pasteboardHasAttachment() {
                Button("Paste from clipboard", .attach) {
                    ingest(items: ChatInbox.pasteboardItems())
                }
            }
        } label: {
            ActionIcon.attach.label("Attach")
                .environment(\.compactActions, true)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .disabled(running)
        .accessibilityLabel("Attach")
    }

    private var field: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(ClientType.body)
            .lineLimit(1...6)
            .focused($focused)
            .padding(.vertical, 8)
            .submitLabel(.send)
            .onSubmit { if !cannotSend { onSend() } }
    }

    private var cannotSend: Bool {
        running
            || model.sending
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private var dropTargeted: Bool {
        urlDropTargeted || textDropTargeted || dataDropTargeted
    }

    private func reportDropTarget() {
        onDropTargeted(dropTargeted)
    }

    private func ingest(photos items: [PhotosPickerItem]) async {
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
        photos = []
        ingest(items: staged)
    }

    private func ingest(items: [ChatInboxItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                await onAttach(item)
            }
        }
    }
}

#endif
