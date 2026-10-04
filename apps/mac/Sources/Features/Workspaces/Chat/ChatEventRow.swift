// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
#if os(macOS)
import AppKit
import ImageIO
#endif

/// One coalesced transcript block: a user turn, assistant markdown, a tool,
/// an edit, an approval, or a quiet usage line.
struct ChatEventRow: View {
    let item: ChatDisplayItem
    let defaultAgentName: String
    let agentLabel: (String) -> String
    let attachmentData: Data?
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    /// The conversation's face, used when a turn fails so the same character
    /// that was thinking is the one that droops.
    var attachmentIsLoading = false
    var attachmentError: String?
    var downloadAttachment: (ChatAttachment) -> Void = { _ in }
    var faceSeed: UInt64 = 0
    /// The row still being written. Its markdown is rebuilt on every token,
    /// so selectable chains (one SelectionOverlay each) are held back until
    /// the turn ends. Copy buttons stay live throughout.
    var isLive = false
    /// Stable per rendered row, including when another window shows this chat.
    @State private var markdownCacheID = UUID().uuidString
    /// Whether this row may run the transcript's spinner. One row does; the
    /// rest of a set of running tools say "Running" in words. See
    /// `TranscriptFollow.spinningRow`.
    var animatesRunning = true
    /// The chat's Detailed level: tool output and diffs start open.
    var expandsOutput = false
    var compactTools = false
    /// Opens or folds a step group, by the group's row id.
    var toggleGroup: (String) -> Void = { _ in }
    /// Answers one of the agent's questions.
    var answerQuestion: (ChatQuestion, String) -> Void = { _, _ in }
    /// This row's question is on its way to the host.
    var answeringQuestion = false
    /// False for a saved copy, which cannot send anything.
    var canAnswerQuestions = true
    /// Opens the folder's changes beside the chat, at one file or all of
    /// them. Nil where there is no live folder to open.
    var reviewChanges: ((String?) -> Void)? = nil
    #if os(macOS)
    /// Whole-card hover for the copy action. Scoping this to the header
    /// saved nothing measurable once segment init was cached and the pin
    /// storms were fixed, and it made the button undiscoverable.
    @State private var hovering = false
    #endif

    /// AppKit's SelectionOverlay is an NSTextField per chain. Lazy-stack
    /// estimate walks measure every row, and a hang report sat in
    /// `setAttributedStringValue` for those overlays. Pointer-gated on Mac
    /// so only the row under the cursor pays for them. Copy buttons stay.
    private var allowsSelection: Bool {
        #if os(macOS)
        !isLive && hovering
        #else
        !isLive
        #endif
    }

    var body: some View {
        content
            .modifier(ChatGroupStepInset(nested: item.groupID != nil))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case let .user(text):
            #if os(macOS)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Spacer(minLength: 48)
                RowCopyButton(text: text, help: L10n.text("apple.chateventrow.copy_prompt.ffc64b8b"), visible: hovering)
                userBubble(text, selectable: allowsSelection)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #else
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Spacer(minLength: 48)
                userBubble(text, selectable: allowsSelection)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            #endif
        case let .assistant(text, backend):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                #if os(macOS)
                HStack(spacing: Theme.Space.s) {
                    Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    RowCopyButton(text: text, help: L10n.text("apple.chateventrow.copy_response.f0f755af"), visible: hovering)
                }
                #else
                HStack(spacing: Theme.Space.s) {
                    Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    RowCopyButton(text: text, help: L10n.text("apple.chateventrow.copy_response.f0f755af"))
                }
                #endif
                MessageMarkdown(
                    text,
                    bodyFont: Theme.chatBody,
                    codeFont: Theme.chatCode,
                    style: .chat,
                    selectable: allowsSelection,
                    live: isLive,
                    liveID: "\(markdownCacheID):\(item.id)"
                )
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.border.opacity(0.72), lineWidth: 1)
            }
            #if os(macOS)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #endif
            .contextMenu {
                Button(L10n.text("apple.chateventrow.copy_response.f0f755af")) { ChatClipboard.copy(text) }
            }
        case let .turnSeparator(backend):
            HStack(spacing: Theme.Space.s) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                Text(L10n.text("apple.chateventrow.0_new_turn.9f36f0a8", "\(agentLabel(backend))"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
            .accessibilityLabel(L10n.text("apple.chateventrow.new_turn_with_0.9f95018a", "\(agentLabel(backend))"))
        case let .thinking(text):
            // Agents write their reasoning in markdown like everything else,
            // so a plain Text left `##` and `**` on screen as punctuation.
            // Quiet headings, because this is an aside and has to keep
            // reading as one.
            //
            // The copy action floats overlaid, never in layout: a header row
            // would put a blank strip over every aside even while hidden.
            VStack(alignment: .leading, spacing: 2) {
                MessageMarkdown(
                    text,
                    bodyFont: Theme.subheadline,
                    codeFont: Theme.monoText(11, relativeTo: .subheadline),
                    style: .aside,
                    selectable: allowsSelection,
                    cacheScope: "thinking",
                    live: isLive,
                    liveID: "\(markdownCacheID):\(item.id)"
                )
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                RowCopyButton(text: text, help: L10n.text("apple.chateventrow.copy_reasoning.5d2976d8"), visible: hovering)
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #endif
            .contextMenu {
                Button(L10n.text("apple.chateventrow.copy_reasoning.5d2976d8")) { ChatClipboard.copy(text) }
            }
        case let .tool(state):
            ToolRow(
                verb: state.verb,
                arg: state.target,
                snippet: state.snippet,
                time: state.duration,
                running: state.running,
                failed: state.failed,
                animatesRunning: animatesRunning,
                expandsOutput: expandsOutput,
                compact: compactTools
            )
        case let .edit(state):
            ChatFileEditRow(state: state, animatesRunning: animatesRunning, expandsOutput: expandsOutput, compact: compactTools)
        case let .group(group):
            ChatStepGroupRow(group: group, animatesRunning: animatesRunning) { toggleGroup(item.id) }
        case let .question(question):
            ChatQuestionCard(question: question, canAnswer: canAnswerQuestions, isSending: answeringQuestion) { text in
                answerQuestion(question, text)
            }
        case let .changes(changes):
            ChatTurnChangesCard(changes: changes, review: reviewChanges)
        case let .attachment(attachment):
            // Stable identity across attachment polls: the revision prop
            // still redraws the row through Equatable when bytes arrive, but
            // recreating the row here restarted the decode and collapsed and
            // regrew its height on every poll.
            ChatResponseAttachment(
                attachment: attachment, data: attachmentData,
                isLoading: attachmentIsLoading, downloadError: attachmentError,
                onDownload: { downloadAttachment(attachment) }
            )
                .id(attachment.id)
        case let .handoff(to, brief):
            ChatHandoffRow(agent: agentLabel(to), brief: brief)
        case let .approval(approval):
            ChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        case let .usage(input, output, cost):
            HStack(spacing: Theme.Space.s) {
                Text(L10n.text("apple.chateventrow.0_in_1_out.f48051a0", "\(input.formatted())", "\(output.formatted())"))
                if let cost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
        case let .failed(text):
            if ChatAuthenticationFailure.isClaudeSignInRefusal(text) {
                Label(L10n.text("apple.agentsetup.history"), systemImage: "person.crop.circle.badge.key")
                    .font(Theme.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    PersonaMark(seed: faceSeed, size: 26, state: .failed)
                    Text(text)
                        .font(Theme.callout)
                        .foregroundStyle(Theme.danger)
                        .modifier(SelectableWhen(allowsSelection))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button(L10n.text("common.copy")) { ChatClipboard.copy(text) }
                        }
                }
                #if os(macOS)
                .contentShape(.rect)
                .onHover { hovering = $0 }
                #endif
            }
        }
    }
}

/// The user turn bubble, shared by the hover and plain layouts above.
///
/// Height is the wrapped text, not the lazy stack's estimate. A wrapping
/// `Text` in a `LazyVStack` can measure as empty on the first pass, which
/// is a sent prompt that is missing until the next layout (a click off
/// the row and back). Markdown already asks for this; the bubble did not.
private func userBubble(_ text: String, selectable: Bool) -> some View {
    Text(text)
        .font(Theme.chatBody)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(SelectableWhen(selectable))
        .padding(Theme.Space.m)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button(L10n.text("common.copy")) { ChatClipboard.copy(text) }
        }
}

/// `.textSelection(.enabled)` only when the row is meant to pay for an overlay.
private struct SelectableWhen: ViewModifier {
    var enabled: Bool
    init(_ enabled: Bool) { self.enabled = enabled }

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

/// One measured text instead of a row per line.
///
/// An expanded diff as `DiffBody` is hundreds of attribute-graph nodes that
/// every transcript measuring pass re-stamps; a live sample of a stopped
/// application sat in exactly that. One `Text` with colored runs measures
/// once, selects and copies as a whole, and reads the same.
func diffColoredText(_ patch: String, lineLimit: Int) -> (text: AttributedString, cut: Int) {
    var out = AttributedString()
    var shown = 0
    var total = 0
    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        total += 1
        guard shown < lineLimit else { continue }
        shown += 1
        var line = AttributedString(String(raw) + "\n")
        line.foregroundColor =
            (raw.hasPrefix("+") && !raw.hasPrefix("+++")) ? Theme.diffAdded
            : (raw.hasPrefix("-") && !raw.hasPrefix("---")) ? Theme.diffRemoved
            : raw.hasPrefix("@@") ? Color.secondary
            : Color.primary
        out += line
    }
    return (out, total - shown)
}

#if os(macOS)
/// Image dimensions from the file header, without decoding pixels. Used to
/// reserve an attachment row's frame before its image arrives, so the decode
/// landing shifts no layout mid-scroll.
private enum ChatImageDims {
    private static let cache: NSCache<NSData, NSNumber> = {
        let cache = NSCache<NSData, NSNumber>()
        cache.countLimit = 32
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func aspect(of data: Data) -> CGFloat? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let aspect = (5...8).contains(orientation) ? height / width : width / height
        cache.setObject(NSNumber(value: aspect), forKey: key, cost: data.count)
        return aspect
    }
}
#endif

/// A response file is part of the conversation, not a path printed into it.
/// Images get a useful inline preview; every other type gets the same compact
/// openable file card. Data came through the owning host, so this also works
/// for chats running on another paired machine.
private struct ChatResponseAttachment: View {
    let attachment: ChatAttachment
    let data: Data?
    var isLoading: Bool
    var downloadError: String?
    var onDownload: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: data == nil ? onDownload : open) {
            VStack(alignment: .leading, spacing: 0) {
                if let aspect = imageAspect {
                    Color.clear
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .overlay {
                            if let image {
                                image.resizable().scaledToFit()
                            }
                        }
                        .clipped()
                        .background(Theme.background)
                }
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: fileSymbol)
                        .font(Theme.font(14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24, height: 24)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.name)
                            .font(Theme.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(fileDetail)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if data == nil {
                        ActionIcon.download.label(downloadError == nil ? L10n.text("apple.chateventrow.download.d6eafe82") : L10n.text("common.retry"))
                            .font(Theme.callout)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Image(systemName: "arrow.up.forward.app")
                            .font(Theme.font(11, weight: .semibold))
                            .foregroundStyle(hovering ? Theme.accent : Color.secondary)
                    }
                }
                .padding(Theme.Space.s)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        // Idle only. The transcript stack drops hit testing while scrolling
        // so a file card sliding under the pointer cannot start a hover
        // storm, the same gate the copy buttons use. Hover comes back 0.35s
        // after the last moved frame.
        .onHover { hovering = $0 }
        .help(data == nil ? L10n.text("apple.chateventrow.download_0.465e0e80", "\(attachment.name)") : L10n.text("apple.chateventrow.open_0.e71b4013", "\(attachment.name)"))
        .task(id: data) {
            guard let data, attachment.mediaType?.hasPrefix("image/") == true else { return }
            // SwiftUI restarts a row's task when it re-enters the viewport.
            // Keep its decoded image and geometry on those appearances.
            guard decodedData != data else { return }
            #if os(macOS)
            let result = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard !Task.isCancelled else { return }
            decodedData = data
            decodedImage = result.map { Image(nsImage: $0) }
            #endif
        }
    }

    @State private var decodedImage: Image?
    @State private var decodedData: Data?
    // Header metadata is available before the async task starts, so the first
    // layout already has the final image box. Pixels only paint its overlay.
    private var imageAspect: CGFloat? {
        guard let data, attachment.mediaType?.hasPrefix("image/") == true else { return nil }
        #if os(macOS)
        return ChatImageDims.aspect(of: data)
        #else
        return nil
        #endif
    }

    private var image: Image? {
        decodedData == data ? decodedImage : nil
    }

    private var fileDetail: String {
        if let downloadError { return downloadError }
        let kind = attachment.mediaType ?? L10n.text("apple.chateventrow.file.50009ce1")
        guard let size = attachment.size else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private var fileSymbol: String {
        let type = attachment.mediaType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("video/") { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") || type.contains("json") { return "doc.text" }
        return "doc"
    }

    private func open() {
        guard let data else { return }
        #if os(macOS)
        do {
            let url = try ChatFileStaging.stage(data, id: attachment.id, name: attachment.name)
            NSWorkspace.shared.open(url)
            Task { await ChatAttachmentCache.shared.maintain() }
        } catch {
            NSSound.beep()
        }
        #endif
    }
}

/// A lightweight streaming cue that sits at the same left edge as an agent
/// reply. It makes an in-progress turn feel like a conversation without
/// reserving the visual weight of another card. Height is fixed so a mood
/// change cannot shove the transcript.
struct ChatWorkingIndicator: View {
    /// The conversation's own face, so the thing that moves while you wait is
    /// the character you already associate with this chat.
    var seed: UInt64
    var mood: PersonaMood = .thinking
    /// What a running tool is doing, in words. Empty leaves the mood's own word.
    var step: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // Thinking is the one state that can last a minute, and one loop
            // held that long stops reading as thought and starts reading as a
            // hang. So the character keeps changing what thinking looks like.
            // Everything else here is short and says exactly one thing.
            if mood == .thinking {
                PersonaPastime(seed: seed, size: 26, doing: .thought, pokeable: false)
            } else {
                PersonaMark(seed: seed, size: 26, state: mood)
            }
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TranscriptFollow.seatHeight)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// A running tool names the step. Every other mood uses its own word.
    private var label: String {
        if mood == .working, let step, !step.isEmpty { return step }
        return mood.label
    }
}

/// The point where a conversation changed hands.
///
/// A backend switch used to be invisible and lossy: the incoming agent got a
/// blank page and the person had to re-explain their own project to a second
/// robot in the same window. It now receives a summary folded from the
/// transcript, and this row is where that fact lives.
///
/// The summary is disclosed, not hidden. It is text tokenstat wrote and put in
/// front of somebody's agent on their behalf, which is exactly the kind of
/// thing that should never be invisible to them.
struct ChatHandoffRow: View {
    let agent: String
    let brief: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                    .frame(maxWidth: 40)
                Image(systemName: "arrow.left.arrow.right")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(L10n.text("apple.chateventrow.handed_to_0.902d7234", "\(agent)"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                if !brief.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? L10n.text("apple.chateventrow.hide_summary.4cf94a81") : L10n.text("apple.chateventrow.what_it_was_told.4b2128b2"))
                            Image(systemName: "chevron.right")
                                .font(Theme.font(9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
            if expanded {
                Text(brief)
                    .font(Theme.monoText(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.chateventrow.handed_to_0_with_a_summary_of_the_conversa.136c6fc3", "\(agent)"))
    }
}

/// One tool call, waiting on a person, in the place it happened.
///
/// Inline rather than a sheet. A modal over a streaming transcript loses your
/// place, and a prompt that can only be answered one way is how a turn wedges.
/// The card carries a countdown because the wait is bounded: the backend gives
/// up after `chat_gate::GATE_TIMEOUT_SECONDS` and the request is refused, and
/// a deadline nobody can see is a trap rather than a safeguard.
struct ChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: outcome.symbol)
                    .foregroundStyle(outcome.tint)
                Text(outcome.title)
                    .font(Theme.callout.weight(.semibold))
                Spacer(minLength: Theme.Space.s)
                if isPending, let remaining = remainingText {
                    Text(remaining)
                        .font(Theme.numeric(11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(L10n.text("apple.chateventrow.0_left_to_answer.63343d2a", "\(remaining)"))
                }
                Text(SeatStep.approvalWord(verb: approval.verb, pending: isPending))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(outcome.tint.opacity(0.12), in: Capsule())
            }
            Text(approval.preview)
                .font(Theme.monoText(11))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .lineLimit(4)
            if isPending {
                ChatApprovalActions(approval: approval, resolve: resolve)
                if let note = SeatStep.allowAlwaysNote(verb: approval.verb, shellPrefix: approval.shellPrefix) {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(outcome.detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isPending ? outcome.tint.opacity(0.55) : Theme.border,
                    lineWidth: isPending ? 1.5 : 1
                )
        }
        .task(id: isPending) {
            guard isPending else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var outcome: ChatApprovalOutcome {
        ChatApprovalOutcome(approval: approval, isPending: isPending)
    }

    private var remainingText: String? {
        let seconds = Int((Double(approval.expiresAtMs) / 1000 - now.timeIntervalSince1970).rounded())
        guard seconds > 0 else { return nil }
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

/// Allow, Always allow, Deny. One row, one meaning each, shared by the card in
/// the transcript and the bar pinned above the composer so the two can never
/// offer different answers to the same question.
struct ChatApprovalActions: View {
    let approval: ChatApproval
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(L10n.text("apple.chateventrow.allow.e213c161"), .allow) { resolve(approval, "allow") }
                .buttonStyle(AccentButtonStyle(small: true))
                .keyboardShortcut(.return, modifiers: [.command])
            Button(L10n.text("apple.chateventrow.always_allow.977618bd"), .allow) { resolve(approval, "allowAlways") }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Spacer(minLength: 0)
            Button(L10n.text("apple.chateventrow.deny.05a2d733"), .deny, role: .destructive) { resolve(approval, "deny") }
                .buttonStyle(DestructiveButtonStyle(small: true))
        }
    }
}

/// How an approval reads once it has an answer.
///
/// Named states rather than "no longer waiting". Somebody scrolling back wants
/// to know what happened, and "this was denied" and "nobody was here in time"
/// are different things that both stopped the same tool.
struct ChatApprovalOutcome {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    init(approval: ChatApproval, isPending: Bool) {
        if isPending {
            self.init(
                title: L10n.text("apple.chateventrow.permission_needed.4e25d34a"),
                detail: "",
                symbol: "hand.raised.fill",
                tint: Theme.accent
            )
        } else if approval.decision == "allow" {
            self.init(
                title: L10n.text("apple.chateventrow.allowed.1bb201d1"),
                detail: L10n.text("apple.chateventrow.you_allowed_this_and_the_agent_went_ahead.59bfbbb2"),
                symbol: ActionIcon.allow.symbol,
                tint: Theme.accent
            )
        } else if approval.decision == "deny" {
            self.init(
                title: L10n.text("apple.chateventrow.denied.da404deb"),
                detail: L10n.text("apple.chateventrow.this_was_refused_the_agent_was_told_not_to.fca7c9dc"),
                symbol: ActionIcon.deny.symbol,
                tint: Theme.danger
            )
        } else {
            self.init(
                title: L10n.text("apple.chateventrow.expired.424a2551"),
                detail: L10n.text("apple.chateventrow.nobody_answered_in_time_so_the_agent_was_r.b31abdc6"),
                symbol: "clock",
                tint: Theme.warning
            )
        }
    }

    private init(title: String, detail: String, symbol: String, tint: Color) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }
}

/// Compared by value so a transcript can skip a row that did not move.
///
/// The closures are the same two functions on every draw and cannot be
/// compared. Attachment bytes are not compared either: presence, loading and
/// error are enough. The revision is global (one file arriving used to
/// rebuild every markdown row in the window), so only an attachment card
/// looks at it, and even there presence wins over the counter.
extension ChatEventRow: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item
            && lhs.defaultAgentName == rhs.defaultAgentName
            && lhs.isPending == rhs.isPending
            && lhs.faceSeed == rhs.faceSeed
            && lhs.isLive == rhs.isLive
            && lhs.animatesRunning == rhs.animatesRunning
            && lhs.expandsOutput == rhs.expandsOutput
            && lhs.compactTools == rhs.compactTools
            && lhs.answeringQuestion == rhs.answeringQuestion
            && lhs.canAnswerQuestions == rhs.canAnswerQuestions
            && (lhs.reviewChanges == nil) == (rhs.reviewChanges == nil)
        else { return false }
        if case .attachment = lhs.item.kind {
            return lhs.attachmentIsLoading == rhs.attachmentIsLoading
                && lhs.attachmentError == rhs.attachmentError
                && (lhs.attachmentData == nil) == (rhs.attachmentData == nil)
        }
        return true
    }
}
