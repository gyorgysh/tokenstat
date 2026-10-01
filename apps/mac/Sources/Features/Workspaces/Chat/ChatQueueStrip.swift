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
                    Button(L10n.text("apple.chatqueuestrip.view_pending.ed59515e"), .more) { showingQueue = true }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .help(L10n.text("apple.chatqueuestrip.review_messages_waiting_to_send_after_this.fe4d5f59"))
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
        if offline, items.first?.needsReceipt == true { return L10n.text("apple.chatqueuestrip.delivery_needs_checking_reconnect_to_revie.c2182f4e") }
        if offline { return items.first?.whenConnected == true ? L10n.text("apple.chatqueuestrip.waiting_for_connection_cancel_by_removing.e4b6b3d3") : L10n.text("apple.chatqueuestrip.paused_reconnect_to_review_delivery.1f9b08dc") }
        if items.first?.needsReceipt == true { return L10n.text("apple.chatqueuestrip.delivery_needs_checking.62805e9a") }
        if items.first?.delivery == .needsReview { return L10n.text("apple.chatqueuestrip.review_the_conversation_before_sending.62bc9ce3") }
        if items.first?.delivery == .ready { return L10n.text("apple.chatqueuestrip.ready_choose_send_now_when_you_are_ready.f283a341") }
        if paused { return L10n.text("apple.chatqueuestrip.paused_on_this_device_choose_send_now_to_c.29cb28cc") }
        return items.count <= 1 ? L10n.text("apple.chatqueuestrip.waiting_to_send_after_this_turn.103f59e4") : L10n.text("apple.chatqueuestrip.waiting_to_send_after_this_turn_0.a42fb840", "\(items.count)")
    }
}

/// A short note parked for the next tool step, above the waiting messages.
///
/// It is not a queued prompt. The agent reads it beside the next result, and
/// removing it drops the note before that step arrives.
struct ChatSteerNoteBanner: View {
    let note: String
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(L10n.text("apple.chatqueuestrip.on_the_next_step.78ea7972"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(L10n.text("common.remove"), .dismiss, action: onRemove)
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .help(L10n.text("apple.chatqueuestrip.remove_this_note.80951b12"))
            }
            Text(note)
                .font(Theme.callout)
                .lineLimit(3)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.chatqueuestrip.on_the_next_step_0.81127e40", "\(note)"))
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
            title: L10n.text("apple.chatqueuestrip.pending_messages.d71048f1"),
            subtitle: L10n.text("apple.chatqueuestrip.new_queues_wait_for_this_turn_send_when_co.97bd8c08"),
            icon: .scheduled,
            scrolls: false,
            onClose: onClose
        ) {
            queueList
        } actions: {
            Spacer(minLength: 0)
            Button(L10n.text("common.done"), .done) { onClose() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 520, height: 480)
        #else
        NavigationStack {
            queueList
                .background(Theme.background)
                .navigationTitle(L10n.text("apple.chatqueuestrip.pending_messages.d71048f1"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("common.done"), .done) { onClose() }
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
                Text(L10n.text("apple.chatqueuestrip.drag_to_reorder_messages_marked_send_when.07ceb60d"))
            } footer: {
                Text(L10n.text("apple.chatqueuestrip.send_now_stops_the_current_turn_check_deli.e8ba1f87"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    #if os(macOS)
    @State private var draggingID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One card per message, no section box. The sheet subtitle already says
    /// where these go and in what order; the footnote keeps what Send now
    /// does, which otherwise lived only in a tooltip.
    private var macQueueList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.s) {
                ForEach(items) { item in
                    macQueueRow(item)
                }
                Text(L10n.text("apple.chatqueuestrip.send_now_stops_the_current_turn_check_deli.e8ba1f87"))
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
                .help(L10n.text("apple.chatqueuestrip.drag_to_reorder_or_focus_and_press_command.c1dd048f"))
                .focusable()
                .accessibilityLabel(L10n.text("apple.chatqueuestrip.reorder_message.66f1eea2"))
                .accessibilityValue(L10n.text("apple.chatqueuestrip.message_0_of_1.5a65876d", "\(items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? 1)", "\(items.count)"))
                .accessibilityActions {
                    if items.first?.id != item.id {
                        Button(L10n.text("apple.chatqueuestrip.move_up.c66feb5e")) { shift(item, by: -1) }
                    }
                    if items.last?.id != item.id {
                        Button(L10n.text("apple.chatqueuestrip.move_down.40bb50da")) { shift(item, by: 1) }
                    }
                }
                .onKeyPress(.upArrow, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    shift(item, by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    shift(item, by: 1)
                    return .handled
                }
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
                reduceMotion: reduceMotion,
                onMove: onMove
            )
        )
    }
    private func shift(_ item: ChatQueuedMessage, by offset: Int) {
        guard let from = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(from + offset) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            onMove(IndexSet(integer: from), offset > 0 ? from + offset + 1 : from + offset)
        }
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
    let reduceMotion: Bool
    let onMove: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = items.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
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
                Text(L10n.text("apple.chatqueuestrip.reconnect_to_send_or_check_delivery_you_ca.418c13de"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            if item.needsReceipt {
                Text(L10n.text("apple.chatqueuestrip.that_computer_has_not_confirmed_this_messa.143c63eb"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            } else if item.delivery == .needsReview {
                Text(L10n.text("apple.chatqueuestrip.review_the_live_conversation_first_use_lat.92fd9e6f"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            } else if item.delivery == .ready {
                Text(L10n.text("apple.chatqueuestrip.ready_with_the_conversation_context_you_la.c69bb317"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            } else if item.delivery == .failed {
                Text(L10n.text("apple.chatqueuestrip.the_last_attempt_was_refused_your_message.4ef87f5b"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("common.copy"), .copy) { copyText() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Spacer(minLength: 0)
                Group {
                    if item.delivery == .needsReview {
                        Button(L10n.text("apple.chatqueuestrip.use_latest_context.a29959ec"), .refresh, action: onSendNow)
                    } else {
                        Button(item.needsReceipt ? L10n.text("apple.chatqueuestrip.check_delivery.b8e3662d") : L10n.text("apple.chatqueuestrip.send_now.58803287"), .send, action: onSendNow)
                    }
                }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(offline)
                    .help(item.needsReceipt ? L10n.text("apple.chatqueuestrip.ask_the_host_whether_it_accepted_this_mess.9803fa8c") : item.delivery == .needsReview ? L10n.text("apple.chatqueuestrip.prepare_this_message_using_the_conversatio.cf0e4a1d") : L10n.text("apple.chatqueuestrip.stop_this_turn_so_this_message_goes_out_ne.d09eed4c"))
                Button(item.needsReceipt ? L10n.text("apple.chatqueuestrip.remove_copy.63d1aef0") : L10n.text("common.remove"), .delete, action: onRemove)
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
            TextField(L10n.text("apple.chatqueuestrip.message.2f77668a"), text: $draft, axis: .vertical)
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
        TextField(L10n.text("apple.chatqueuestrip.message.2f77668a"), text: $draft, axis: .vertical)
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
        return L10n.text("apple.chatqueuestrip.0_attached.62e5c2f9", "\(names.count)")
    }
}
