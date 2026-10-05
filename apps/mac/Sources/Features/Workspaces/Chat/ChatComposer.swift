// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers

/// Repositions one set of controls instead of measuring two complete
/// composers through `ViewThatFits` on every transcript layout pass.
/// Child size changes invalidate the cache, including quota badge updates.
private struct ComposerUtilityLayout: Layout {
    let spacing: CGFloat
    let controlsGap: CGFloat

    struct Arrangement {
        let size: CGSize
        let origins: [CGPoint]
        let sizes: [CGSize]
    }

    struct Cache {
        var ideal: [CGSize] = []
        var arrangements: [CGFloat: Arrangement] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let plan = arrangement(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + plan.origins[index].x, y: bounds.minY + plan.origins[index].y),
                anchor: .topLeading,
                proposal: ProposedViewSize(plan.sizes[index])
            )
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    private func arrangement(width offered: CGFloat?, subviews: Subviews, cache: inout Cache) -> Arrangement {
        guard subviews.count == 3 else { return Arrangement(size: .zero, origins: [], sizes: []) }
        if cache.ideal.isEmpty { cache.ideal = subviews.map { $0.sizeThatFits(.unspecified) } }
        let ideal = cache.ideal
        let oneRowWidth = ideal.reduce(0) { $0 + $1.width } + spacing + controlsGap
        let width = offered.flatMap { $0.isFinite ? max(0, $0) : nil } ?? oneRowWidth
        if let held = cache.arrangements[width] { return held }
        let plan: Arrangement
        if width >= oneRowWidth {
            let height = ideal.map(\.height).max() ?? 0
            plan = Arrangement(
                size: CGSize(width: width, height: height),
                origins: [
                    CGPoint(x: 0, y: (height - ideal[0].height) / 2),
                    CGPoint(x: ideal[0].width + spacing, y: (height - ideal[1].height) / 2),
                    CGPoint(x: width - ideal[2].width, y: (height - ideal[2].height) / 2)
                ],
                sizes: ideal
            )
        } else {
            let controls = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let trailing = subviews[2].sizeThatFits(
                ProposedViewSize(width: max(0, width - ideal[0].width - spacing), height: nil)
            )
            let bottomHeight = max(ideal[0].height, trailing.height)
            let bottomY = controls.height + spacing
            plan = Arrangement(
                size: CGSize(width: width, height: bottomY + bottomHeight),
                origins: [
                    CGPoint(x: 0, y: bottomY + (bottomHeight - ideal[0].height) / 2),
                    .zero,
                    CGPoint(x: width - trailing.width, y: bottomY + (bottomHeight - trailing.height) / 2)
                ],
                sizes: [ideal[0], controls, trailing]
            )
        }
        if cache.arrangements.count >= 16 { cache.arrangements.removeAll(keepingCapacity: true) }
        cache.arrangements[width] = plan
        return plan
    }
}

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
    /// A message typed now is read on the agent's next step, rather than
    /// waiting until the turn ends.
    var sendsAsNote: Bool = false
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
                Button(L10n.text("apple.chatcomposer.send_when_connected.c2aae57a"), .scheduled) { model.queueDraftWhenConnected() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.stagingAttachments > 0 || model.unconfirmedSend != nil || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty))
            }
            if model.selectedBackendMissing {
                ChatAgentAvailabilityNotice(model: model, chat: chat)
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
            ComposerUtilityLayout(spacing: Theme.Space.s, controlsGap: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    attachControl
                    ChatFastModeButton(model: model, chat: chat, locked: running)
                }
                ChatComposerControls(model: model, chat: chat, locked: running)
                HStack(spacing: Theme.Space.s) {
                    turnStatus
                    ComposerLimitsBadge(backend: chat.backend)
                    turnActions
                }
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
        .accessibilityLabel(L10n.text("apple.chatcomposer.message.2f77668a"))
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
            Button(L10n.text("apple.chatcomposer.choose_files.1157defa"), .attach) {
                importOwner = model.currentReference
                importing = true
            }
            if ChatInbox.pasteboardHasAttachment() {
                Button(L10n.text("apple.chatcomposer.paste_from_clipboard.dc2d6f20"), .attach) {
                    ingest(items: ChatInbox.pasteboardItems())
                }
            }
        } label: {
            ActionIcon.attach.label(L10n.text("apple.chatcomposer.attach.d406ade2"))
                .environment(\.compactActions, true)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .help(L10n.text("apple.chatcomposer.attach_files_or_images.b548dd44"))
        .accessibilityLabel(L10n.text("apple.chatcomposer.attach.d406ade2"))
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
            Text(L10n.text("apple.chatcomposer.working_00h_00m.df5f29d2"))
                .hidden()
                .accessibilityHidden(true)
            if running {
                if let since = model.turnStartedAt(for: chat.id) {
                    TurnElapsedText(since: since)
                } else {
                    // The stamp lands on the same write that reports running,
                    // so this is a single frame at most: the word without the
                    // clock beats no word at all.
                    Text(L10n.text("common.working"))
                        .accessibilityLabel(L10n.text("common.working"))
                }
            }
        }
        .font(Theme.font(11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.accent)
        .lineLimit(1)
        .fixedSize()
    }

    /// Stop and Send, over an invisible copy of the buttons on screen.
    ///
    /// Either can come and go on its own: Stop only while a turn runs, Send
    /// only with something to send. The copy mirrors exactly what is drawn,
    /// so the block hugs the visible buttons instead of holding the old
    /// widest-pair width, which squashed the quota badge on a narrow well.
    /// The frame below then reserves one small icon button's width, so a
    /// single Stop or Send coming or going moves nothing beside it: typing
    /// the first word, sending, a turn starting or ending all hold still.
    /// Only the pair (a draft queued mid-turn) reflows the row. The copy
    /// carries no shortcut, menu or action, so there is one of each in the
    /// row.
    private var turnActions: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: Theme.Space.s) {
                if running {
                    Button(L10n.text("common.stop"), .stop) {}
                        .buttonStyle(DestructiveButtonStyle(small: true))
                }
                if !cannotSend {
                    Button(sendTitle, .send) {}
                        .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            .environment(\.compactActions, true)
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            HStack(spacing: Theme.Space.s) {
                if running {
                    Button(L10n.text("common.stop"), .stop) { onStop() }
                        .buttonStyle(DestructiveButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .keyboardShortcut(.cancelAction)
                }
                if !cannotSend {
                    Button(sendTitle, .send, action: onSend)
                        .buttonStyle(AccentButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .help(sendsAsNote ? L10n.text("apple.chatcomposer.the_agent_reads_this_on_its_next_step.aab7b1c7") : running ? L10n.text("apple.chatcomposer.waits_until_this_turn_finishes_stop_and_se.2df81427") : L10n.text("apple.chatcomposer.send.f6f4688f"))
                        .contextMenu {
                            if running {
                                Button(L10n.text("apple.chatcomposer.stop_and_send_now.8ad0a50d"), .send, action: onSendNow)
                            }
                        }
                }
            }
        }
        .frame(minWidth: 44, alignment: .trailing)
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
                    Text(L10n.text("apple.chatcomposer.drop_to_attach.34a7a637"))
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

    private var sendTitle: String {
        if sendsAsNote { return L10n.text("apple.chatcomposer.next_step.298a9207") }
        return running ? L10n.text("apple.chatcomposer.send_after_this_turn.012fc8c3") : L10n.text("apple.chatcomposer.send.f6f4688f")
    }

    private var cannotSend: Bool {
        // A saved copy is read and drafted in, never sent from: the banner
        // above says why, and the field stays editable for those drafts.
        model.selectedBackendMissing || model.savedCopy != nil
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
                ActionIcon.dismiss.label(L10n.text("common.remove"))
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
            .accessibilityLabel(L10n.text("apple.chatcomposer.remove_0.dfbfd0da", "\(attachment.name)"))
            #if os(macOS)
            .offset(x: 5, y: -5)
            #endif
        }
        .help(unavailable ? L10n.text("apple.chatcomposer.the_original_is_not_saved_on_this_device_r.b6f9a2f6") : attachment.name)
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
                Text(unavailable ? L10n.text("apple.chatcomposer.not_saved_here.791263ad") : attachment.name)
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
