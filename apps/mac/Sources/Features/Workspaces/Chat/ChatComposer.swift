// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers

/// The bar under the transcript: attachments as thumbnails, a field, Send.
///
/// One well, not three controls sitting on the page. Drop and paste land here
/// so a screenshot does not have to be saved first. The well lights up in the
/// accent when a drag is over it, the same signal the rest of the app uses.
struct ChatComposer: View {
    @Binding var draft: String
    var attachments: [ChatAttachment]
    var previews: [String: Data]
    var running: Bool
    var placeholder: String
    var onSend: () -> Void
    var onStop: () -> Void
    var onAttach: (ChatInboxItem) async -> Void
    var onRemove: (ChatAttachment) -> Void

    @State private var importing = false
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            well
                .frame(maxWidth: 780)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
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
            if case let .success(urls) = result {
                ingest(urls: urls)
            }
        }
    }

    private var well: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !attachments.isEmpty {
                strip
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                attachControl
                field
                if running {
                    Button("Stop", .stop) { onStop() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .environment(\.compactActions, true)
                } else {
                    Button("Send", .send) { onSend() }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .disabled(cannotSend)
                }
            }
        }
        .padding(10)
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
            of: [.fileURL, .image, .png, .jpeg, .gif, .webP, .heic, .tiff, .pdf, .plainText],
            isTargeted: $dropTargeted
        ) { providers in
            Task { await ingest(providers: providers) }
            return true
        }
        .onPasteCommand(of: [.image, .fileURL, .png, .jpeg, .pdf]) { providers in
            Task { await ingest(providers: providers) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropTargeted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: attachments.count)
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
                        onRemove: { onRemove(attachment) }
                    )
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var attachControl: some View {
        Menu {
            Button("Choose files", .attach) { importing = true }
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
        .disabled(running)
        .help("Attach files or images")
        .accessibilityLabel("Attach")
    }

    private var field: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.body)
            .lineLimit(1...8)
            .padding(.vertical, 6)
            #if os(macOS)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.command) {
                    if !cannotSend { onSend() }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(KeyEquivalent("v"), phases: .down) { press in
                guard press.modifiers.contains(.command),
                      ChatInbox.pasteboardHasAttachment()
                else { return .ignored }
                ingest(items: ChatInbox.pasteboardItems())
                return .handled
            }
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
        running || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ingest(urls: [URL]) {
        ingest(items: urls.compactMap(ChatInbox.item(from:)))
    }

    private func ingest(providers: [NSItemProvider]) async {
        ingest(items: await ChatInbox.items(from: providers))
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

/// A 76-point tile: the picture itself for images, a typed seat for files.
private struct ChatAttachmentTile: View {
    let attachment: ChatAttachment
    var preview: Data?
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tile
            Button("Remove", .dismiss) { onRemove() }
                .buttonStyle(.plain)
                .environment(\.compactActions, true)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
                .background(Theme.panel, in: Circle())
                .overlay { Circle().strokeBorder(Theme.border, lineWidth: 1) }
                .offset(x: 5, y: -5)
        }
        .help(attachment.name)
        .accessibilityElement(children: .combine)
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
                Text(attachment.name)
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
