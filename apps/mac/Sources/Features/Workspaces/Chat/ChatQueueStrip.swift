// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Messages waiting for the open turn to finish, sitting above the composer.
///
/// The host will not take a second send until this turn ends, so the next
/// prompt waits here. One waiting message stays on the strip, where it can
/// still be edited, dropped, or sent now. Two or more open from View pending,
/// so the list does not cover the transcript.
struct ChatQueueStrip: View {
    let items: [ChatQueuedMessage]
    var onChange: (ChatQueuedMessage, String) -> Void
    var onRemove: (ChatQueuedMessage) -> Void
    var onSendNow: (ChatQueuedMessage) -> Void

    @State private var showingQueue = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if items.count > 1 {
                    Button("View pending", .more) { showingQueue = true }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .help("Review messages waiting to send after this turn")
                }
            }
            if let next = items.first {
                ChatQueueRow(
                    item: next,
                    compact: true,
                    onChange: { onChange(next, $0) },
                    onRemove: { onRemove(next) },
                    onSendNow: { onSendNow(next) }
                )
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .sheet(isPresented: $showingQueue) {
            ChatPendingMessagesSheet(
                items: items,
                onChange: onChange,
                onRemove: onRemove,
                onSendNow: onSendNow,
                onClose: { showingQueue = false }
            )
        }
        .onChange(of: items.isEmpty) { _, empty in
            if empty { showingQueue = false }
        }
    }

    private var title: String {
        items.count <= 1
            ? "Waiting to send after this turn"
            : "Waiting to send after this turn · \(items.count)"
    }
}

/// The rest of the queue, as a task sheet rather than a system form.
///
/// A NavigationStack sheet on the Mac draws the platform's grey footer and a
/// filled Done, which is the one chrome this product never uses. `ThemedSheet`
/// is the same window as Personas, Add workspace, and the rest.
private struct ChatPendingMessagesSheet: View {
    let items: [ChatQueuedMessage]
    var onChange: (ChatQueuedMessage, String) -> Void
    var onRemove: (ChatQueuedMessage) -> Void
    var onSendNow: (ChatQueuedMessage) -> Void
    var onClose: () -> Void

    var body: some View {
        #if os(macOS)
        ThemedSheet(
            title: "Pending messages",
            subtitle: "These send once the current turn finishes, in this order.",
            icon: .scheduled,
            scrolls: true,
            onClose: onClose
        ) {
            queueList
        } actions: {
            Spacer(minLength: 0)
            Button("Done", .done) { onClose() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 520, height: 480)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("These send once the current turn finishes, in this order. Send now stops that turn so the chosen message goes out next.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    queueList
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle("Pending messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", .done) { onClose() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        #endif
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ThemeRule() }
                ChatQueueRow(
                    item: item,
                    onChange: { onChange(item, $0) },
                    onRemove: { onRemove(item) },
                    onSendNow: { onSendNow(item) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatQueueRow: View {
    let item: ChatQueuedMessage
    var compact = false
    var onChange: (String) -> Void
    var onRemove: () -> Void
    var onSendNow: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if compact {
                compactField
            } else {
                sheetField
            }
            if !item.attachments.isEmpty {
                Text(attachmentLabel)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .padding(.leading, compact ? 24 : 0)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Send now", .send, action: onSendNow)
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help("Stop this turn so this message goes out next")
                Button("Remove", .delete, action: onRemove)
                    .buttonStyle(DestructiveButtonStyle(small: true))
                    .environment(\.compactActions, compact)
            }
        }
        .onAppear { draft = item.text }
        .onChange(of: item.text) { _, text in
            if draft != text { draft = text }
        }
    }

    /// One or two lines on the accent strip, with the clock that marks a wait.
    private var compactField: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: ActionIcon.scheduled.symbol)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, height: 28)
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...2)
                .onChange(of: draft) { _, text in
                    onChange(text)
                }
        }
    }

    /// A themed box on the sheet, so the field is the same object as every
    /// other editor and not a label sitting on a tinted card.
    private var sheetField: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .textFieldStyle(.themedMultiline)
            .lineLimit(1...6)
            .onChange(of: draft) { _, text in
                onChange(text)
            }
    }

    private var attachmentLabel: String {
        let names = item.attachments.map(\.name)
        if names.count == 1 { return names[0] }
        return "\(names.count) attached"
    }
}
