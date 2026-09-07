// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Messages waiting for the open turn to finish, sitting above the composer.
///
/// The host will not take a second send until this turn ends, so the next
/// prompt waits here. It can still be edited, dropped, or sent now, which
/// stops the current turn and goes out as soon as the host is free.
struct ChatQueueStrip: View {
    let items: [ChatQueuedMessage]
    var onChange: (ChatQueuedMessage, String) -> Void
    var onRemove: (ChatQueuedMessage) -> Void
    var onSendNow: (ChatQueuedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                ChatQueueRow(
                    item: item,
                    onChange: { onChange(item, $0) },
                    onRemove: { onRemove(item) },
                    onSendNow: { onSendNow(item) }
                )
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        items.count == 1 ? "Waiting to send" : "Waiting to send · \(items.count)"
    }
}

private struct ChatQueueRow: View {
    let item: ChatQueuedMessage
    var onChange: (String) -> Void
    var onRemove: () -> Void
    var onSendNow: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: ActionIcon.scheduled.symbol)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16, height: 28)
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .lineLimit(1...6)
                    .onChange(of: draft) { _, text in
                        onChange(text)
                    }
            }
            if !item.attachments.isEmpty {
                Text(attachmentLabel)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Send now", .send, action: onSendNow)
                    .buttonStyle(AccentButtonStyle(small: true))
                    .environment(\.compactActions, true)
                Button("Remove", .delete, action: onRemove)
                    .buttonStyle(DestructiveButtonStyle(small: true))
                    .environment(\.compactActions, true)
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { draft = item.text }
        .onChange(of: item.text) { _, text in
            if draft != text { draft = text }
        }
    }

    private var attachmentLabel: String {
        let names = item.attachments.map(\.name)
        if names.count == 1 { return names[0] }
        return "\(names.count) attached"
    }
}
