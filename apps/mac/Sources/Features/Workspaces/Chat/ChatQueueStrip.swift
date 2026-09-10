// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Messages waiting for the open turn to finish, sitting above the composer.
///
/// The host will not take a second send until this turn ends, so the next
/// prompt waits here. One waiting message stays on the strip, where it can
/// still be edited, dropped, or sent now. Two or more open from View pending,
/// so the list does not cover the transcript.
struct ChatQueueStrip: View {
    let items: [ChatQueuedMessage]
    /// Conversation the strip belongs to. Switching threads with the pending
    /// sheet open must close it rather than retarget it at the new chat.
    var owner: WorkReference?
    var paused = false
    var offline = false
    var onChange: (ChatQueuedMessage, String) -> Void
    var onRemove: (ChatQueuedMessage) -> Void
    var onSendNow: (ChatQueuedMessage) -> Void
    var onMove: (IndexSet, Int) -> Void

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
                    offline: offline,
                    onChange: { onChange(next, $0) },
                    onRemove: { onRemove(next) },
                    onSendNow: { onSendNow(next) }
                )
                .id(next.id)
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
                offline: offline,
                onChange: onChange,
                onRemove: onRemove,
                onSendNow: onSendNow,
                onMove: onMove,
                onClose: { showingQueue = false }
            )
        }
        .onChange(of: items.isEmpty) { _, empty in
            if empty { showingQueue = false }
        }
        .onChange(of: owner) { _, _ in
            showingQueue = false
        }
    }

    private var title: String {
        if offline, items.first?.needsReceipt == true { return "Delivery needs checking · Reconnect to review" }
        if offline { return items.first?.whenConnected == true ? "Waiting for connection · Cancel by removing the copy" : "Paused · Reconnect to review delivery" }
        if items.first?.needsReceipt == true { return "Delivery needs checking" }
        if paused { return "Paused on this device · Choose Send now to continue" }
        return items.count <= 1 ? "Waiting to send after this turn" : "Waiting to send after this turn · \(items.count)"
    }
}

/// The rest of the queue, as a task sheet rather than a system form.
///
/// A NavigationStack sheet on the Mac draws the platform's grey footer and a
/// filled Done, which is the one chrome this product never uses. `ThemedSheet`
/// is the same window as Personas, Add workspace, and the rest.
private struct ChatPendingMessagesSheet: View {
    let items: [ChatQueuedMessage]
    var offline = false
    var onChange: (ChatQueuedMessage, String) -> Void
    var onRemove: (ChatQueuedMessage) -> Void
    var onSendNow: (ChatQueuedMessage) -> Void
    var onMove: (IndexSet, Int) -> Void
    var onClose: () -> Void

    var body: some View {
        #if os(macOS)
        ThemedSheet(
            title: "Pending messages",
            subtitle: "New queues wait for this turn. Send when connected keeps your explicit choice; other reopened messages stay paused.",
            icon: .scheduled,
            scrolls: false,
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
            queueList
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

    /// The send order. iOS gets the list with its standard handles, always on
    /// like the tabs editor: an Edit button would be a second step before the
    /// only thing this screen is for. macOS gets plain cards with the same
    /// familiar grip, because a Mac list draws no handles and its grey
    /// section box only repeated the sheet's own words.
    private var queueList: some View {
        #if os(macOS)
        macQueueList
        #else
        List {
            Section {
                ForEach(items) { item in
                    ChatQueueRow(
                        item: item,
                        offline: offline,
                        onChange: { onChange(item, $0) },
                        onRemove: { onRemove(item) },
                        onSendNow: { onSendNow(item) }
                    )
                    .listRowBackground(Theme.background)
                }
                .onMove(perform: onMove)
            } header: {
                Text("Drag to reorder. Messages marked Send when connected keep that choice. Other reopened messages stay paused.")
            } footer: {
                Text("Send now stops the current turn. Check delivery never resends a message.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    #if os(macOS)
    @State private var draggingID: String?

    /// One card per message, no section box. The sheet subtitle already says
    /// where these go and in what order; the footnote keeps what Send now
    /// does, which otherwise lived only in a tooltip.
    private var macQueueList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.s) {
                ForEach(items) { item in
                    macQueueRow(item)
                }
                Text("Send now stops the current turn. Check delivery never resends a message.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
        }
    }

    /// The grip people know from every reorder list, wired to a live move:
    /// rows slide aside as the drag passes, the way the iOS handles do. Only
    /// the grip starts a drag, so selecting text in the field still works.
    private func macQueueRow(_ item: ChatQueuedMessage) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 30)
                .contentShape(.rect)
                .help("Drag to reorder")
                .accessibilityLabel("Reorder message")
                .onDrag {
                    draggingID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
            ChatQueueRow(
                item: item,
                offline: offline,
                onChange: { onChange(item, $0) },
                onRemove: { onRemove(item) },
                onSendNow: { onSendNow(item) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onDrop(
            of: [.text],
            delegate: QueueDropDelegate(
                targetID: item.id,
                items: items,
                draggingID: $draggingID,
                onMove: onMove
            )
        )
    }
    #endif
}

#if os(macOS)
/// Live reorder for the pending-messages sheet: crossing a row moves the
/// dragged message there at once, so the list itself shows the new order
/// instead of waiting for the drop.
private struct QueueDropDelegate: DropDelegate {
    let targetID: String
    let items: [ChatQueuedMessage]
    @Binding var draggingID: String?
    let onMove: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = items.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return }
        withAnimation {
            onMove(IndexSet(integer: from), to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
#endif

private struct ChatQueueRow: View {
    let item: ChatQueuedMessage
    var compact = false
    var offline = false
    var onChange: (String) -> Void
    var onRemove: () -> Void
    var onSendNow: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if compact {
                compactField.disabled(!item.canEdit)
            } else {
                sheetField.disabled(!item.canEdit)
            }
            if !item.attachments.isEmpty {
                Text(attachmentLabel)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .padding(.leading, compact ? 24 : 0)
            }
            if offline {
                Text("Reconnect to send or check delivery. You can still copy, edit unsent text, or remove the local copy.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            if item.needsReceipt {
                Text("The host has not confirmed this message. Check delivery, or copy its text after reviewing the conversation. Removing this copy does not cancel a message already sent.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            } else if item.delivery == .failed {
                Text("The last attempt was refused. Your message is still here.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Copy", .copy) { copyText() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Spacer(minLength: 0)
                Button(item.needsReceipt ? "Check delivery" : "Send now", .send, action: onSendNow)
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(offline)
                    .help(item.needsReceipt ? "Ask the host whether it accepted this message" : "Stop this turn so this message goes out next")
                Button(item.needsReceipt ? "Remove copy" : "Remove", .delete, action: onRemove)
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

    private func copyText() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        #else
        UIPasteboard.general.string = item.text
        #endif
    }

    private var attachmentLabel: String {
        let names = item.attachments.map(\.name)
        if names.count == 1 { return names[0] }
        return "\(names.count) attached"
    }
}
