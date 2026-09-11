// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers

/// The bar under the transcript: message first, compact controls underneath.
///
/// The first row is an uninterrupted writing surface. Attach, agent options
/// and send share one aligned utility row underneath, like a normal chat
/// composer rather than a settings form sitting above a text field.
struct ChatComposer: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @Binding var draft: String
    @Binding var selection: NSRange
    var attachments: [ChatAttachment]
    var previews: [String: Data]
    var running: Bool
    var placeholder: String
    var onSend: () -> Void
    var onSendNow: () -> Void = {}
    var onStop: () -> Void
    var onAttach: (ChatInboxItem, WorkReference) async -> Void
    var onRemove: (ChatAttachment) -> Void
    var onDropProviders: ([NSItemProvider]) -> Void
    var onDropTargeted: (Bool) -> Void

    @State private var importOwner: WorkReference?
    @State private var importing = false
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        well
            .frame(maxWidth: ReadingRoom.laneWidth)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.background)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, let owner = importOwner {
                ingest(items: urls.compactMap(ChatInbox.item(from:)), owner: owner)
            }
        }
    }

    private var well: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.savedCopy != nil {
                Button("Send when connected", .scheduled) { model.queueDraftWhenConnected() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.stagingAttachments > 0 || model.unconfirmedSend != nil || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty))
            }
            if model.draftSaveFailed {
                ChatDraftNotice(retrySave: { model.retryDraftSave() })
            } else if let unconfirmed = model.unconfirmedSend {
                ChatDraftNotice(unconfirmed: unconfirmed,
                                checkAgain: { Task { await model.checkUnconfirmedSend() } })
            }
            if !attachments.isEmpty {
                strip
            }
            field
            HStack(alignment: .center, spacing: Theme.Space.s) {
                attachControl
                ChatComposerControls(
                    model: model,
                    chat: chat,
                    locked: running
                )
                Spacer(minLength: Theme.Space.m)
                turnStatus
                ComposerLimitsBadge(backend: chat.backend)
                turnActions
            }
        }
        #if os(macOS)
        .onExitCommand {
            if running { onStop() }
        }
        #endif
        .padding(12)
        .background(wellFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(wellStroke, lineWidth: dropTargeted ? 1.5 : 1)
        }
        .overlay {
            if dropTargeted {
                dropHint
            }
        }
        .onDrop(
            of: ChatInbox.dropTypes,
            isTargeted: $dropTargeted
        ) { providers in
            onDropProviders(providers)
            return true
        }
        #if os(macOS)
        .onPasteCommand(of: [.image, .fileURL, .png, .jpeg, .pdf]) { providers in
            guard let owner = model.currentReference else { return }
            Task { await ingest(providers: providers, owner: owner) }
        }
        #endif
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropTargeted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: attachments.count)
        .onChange(of: dropTargeted) { _, targeted in
            onDropTargeted(targeted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message")
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
        .padding(.bottom, 2)
    }

    private var attachControl: some View {
        Menu {
            Button("Choose files", .attach) {
                importOwner = model.currentReference
                importing = true
            }
            if ChatInbox.pasteboardHasAttachment() {
                Button("Paste from clipboard", .attach) {
                    ingest(items: ChatInbox.pasteboardItems())
                }
            }
        } label: {
            ActionIcon.attach.label("Attach")
                .environment(\.compactActions, true)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .help("Attach files or images")
        .accessibilityLabel("Attach")
    }

    /// How long this turn has been running, in a slot wide enough for its
    /// longest reading.
    ///
    /// The slot is held whether or not a turn is running, and sits against
    /// the row's flexible gap, so the space it keeps while nothing runs reads
    /// as part of that gap rather than as a hole. Holding it is what stops
    /// the quota badge and the buttons beside it being shoved sideways every
    /// time a turn starts, ends, or the clock passes another digit.
    private var turnStatus: some View {
        ZStack(alignment: .trailing) {
            Text("Working · 00h 00m")
                .hidden()
                .accessibilityHidden(true)
            if running {
                if let since = model.turnStartedAt(for: chat.id) {
                    TurnElapsedText(since: since)
                } else {
                    // The stamp lands on the same write that reports running,
                    // so this is a single frame at most: the word without the
                    // clock beats no word at all.
                    Text("Working")
                        .accessibilityLabel("Working")
                }
            }
        }
        .font(Theme.font(11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.accent)
        .lineLimit(1)
        .fixedSize()
    }

    /// Stop and Send, over an invisible copy of the widest pair.
    ///
    /// Either can come and go on its own: Stop only while a turn runs, Send
    /// only with something to send. The placeholder uses the longest real
    /// string ("Send after this turn") with a fixed minimum width so the
    /// badge beside it holds its place across Dynamic Type. The copy carries
    /// no shortcut, menu or action, so there is one of each in the row.
    private var turnActions: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: Theme.Space.s) {
                Button("Stop", .stop) {}
                    .buttonStyle(DestructiveButtonStyle(small: true))
                Button("Send after this turn", .send) {}
                    .buttonStyle(AccentButtonStyle(small: true))
            }
            .environment(\.compactActions, true)
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .frame(minWidth: 180)
            HStack(spacing: Theme.Space.s) {
                if running {
                    Button("Stop", .stop) { onStop() }
                        .buttonStyle(DestructiveButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .keyboardShortcut(.cancelAction)
                }
                if !cannotSend {
                    Button(running ? "Send after this turn" : "Send", .send, action: onSend)
                        .buttonStyle(AccentButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .help(running ? "Waits until this turn finishes. Stop and send now is on the queued message." : "Send")
                        .contextMenu {
                            if running {
                                Button("Stop and send now", .send, action: onSendNow)
                            }
                        }
                }
            }
        }
    }

    private var field: some View {
        #if os(macOS)
        ChatDraftView(
            text: $draft,
            selection: $selection,
            placeholder: placeholder,
            enabled: !model.sending,
            onSend: {
                if !cannotSend { onSend() }
            },
            onStop: {
                if running { onStop() }
            },
            onPasteAttachments: {
                ingest(items: ChatInbox.pasteboardItems())
            }
        )
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 160, alignment: .topLeading)
        .layoutPriority(1)
        .fixedSize(horizontal: false, vertical: true)
        #else
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.body)
            .lineLimit(1...8)
            .padding(.vertical, 6)
            .submitLabel(.send)
            .onSubmit { if !cannotSend { onSend() } }
        #endif
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accentSoft.opacity(0.94))
            .overlay {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ActionIcon.attach.symbol)
                        .font(Theme.font(15, weight: .semibold))
                    Text("Drop to attach")
                        .font(Theme.callout.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .allowsHitTesting(false)
    }

    private var wellFill: Color {
        dropTargeted ? Theme.accentSoft : Theme.panel
    }

    private var wellStroke: Color {
        dropTargeted ? Theme.accent : Theme.border
    }

    private var cannotSend: Bool {
        // A saved copy is read and drafted in, never sent from: the banner
        // above says why, and the field stays editable for those drafts.
        model.savedCopy != nil
            || model.stagingAttachments > 0
            || model.sending
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    private func ingest(providers: [NSItemProvider], owner: WorkReference) async {
        ingest(items: await ChatInbox.items(from: providers), owner: owner)
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

/// A 76-point tile: the picture itself for images, a typed seat for files.
struct ChatAttachmentTile: View {
    let attachment: ChatAttachment
    var preview: Data?
    var unavailable = false
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tile
            Button(action: onRemove) {
                ActionIcon.dismiss.label("Remove")
                    .font(Theme.fixed(8, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 18)
                    .background(Theme.panel, in: Circle())
                    .overlay { Circle().strokeBorder(Theme.border, lineWidth: 1) }
                    #if !os(macOS)
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
                    #endif
            }
            .buttonStyle(.plain)
            .environment(\.compactActions, true)
            .accessibilityLabel("Remove \(attachment.name)")
            #if os(macOS)
            .offset(x: 5, y: -5)
            #endif
        }
        .help(unavailable ? "The original is not saved on this device. Reconnect or remove it and attach the original again." : attachment.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
    }

    @ViewBuilder
    private var tile: some View {
        if let preview, let image = ChatInbox.image(from: preview) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                }
        } else {
            VStack(spacing: 6) {
                Image(systemName: fileSymbol)
                    .font(Theme.font(16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(unavailable ? "Not saved here" : attachment.name)
                    .font(Theme.mono(9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .padding(8)
            .frame(width: 76, height: 76)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        }
    }

    private var fileSymbol: String {
        let type = (attachment.mediaType ?? "").lowercased()
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        if type.contains("pdf") || ext == "pdf" { return "doc.richtext" }
        if type.contains("text") || ["txt", "md", "csv", "json"].contains(ext) {
            return "doc.text"
        }
        if ["swift", "rs", "py", "js", "ts", "go", "rb"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return ActionIcon.attach.symbol
    }
}
