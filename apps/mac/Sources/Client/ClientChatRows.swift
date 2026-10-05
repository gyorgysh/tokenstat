// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI
import UIKit
import ImageIO
import QuickLook

/// Phone-sized transcript blocks. Assistant prose and tools are the same
/// views as the Mac. Edits use `DiffLineRow` so a hunk does not spend a
/// quarter of the screen on two gutters.
struct ClientChatEventRow: View {
    let item: ChatDisplayItem
    let attachmentData: Data?
    let defaultAgentName: String
    let agentLabel: (String) -> String
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    var attachmentIsLoading = false
    var attachmentError: String?
    var downloadAttachment: (ChatAttachment) -> Void = { _ in }
    var openAttachment: (ChatAttachment, Data) -> Void = { _, _ in }
    var faceSeed: UInt64 = 0
    /// The row still being written. Selectable chains are held back until
    /// the turn ends; copy buttons stay live throughout.
    var isLive = false
    /// Stable per rendered row, independent of other chats and windows.
    @State private var markdownCacheID = UUID().uuidString
    /// Whether this row may run the transcript's spinner. See
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

    var body: some View {
        content
            .modifier(ChatGroupStepInset(nested: item.groupID != nil))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case let .user(text):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Spacer(minLength: 36)
                Text(text)
                    .font(Theme.chatBody)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Theme.Space.m)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contextMenu {
                        Button(L10n.text("common.copy")) { ChatClipboard.copy(text) }
                    }
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .assistant(text, backend):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    RowCopyButton(text: text, help: L10n.text("apple.clientchatrows.copy_response.f0f755af"))
                }
                MessageMarkdown(
                    text,
                    bodyFont: Theme.chatBody,
                    codeFont: Theme.chatCode,
                    style: .chat,
                    selectable: !isLive,
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
            .contextMenu {
                Button(L10n.text("apple.clientchatrows.copy_response.f0f755af")) { ChatClipboard.copy(text) }
            }
        case let .turnSeparator(backend):
            HStack(spacing: Theme.Space.s) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                Text(L10n.text("apple.clientchatrows.0_new_turn.9f36f0a8", "\(agentLabel(backend))"))
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
            .accessibilityLabel(L10n.text("apple.clientchatrows.new_turn_with_0.9f95018a", "\(agentLabel(backend))"))
        case let .thinking(text):
            // Same as the Mac: reasoning is markdown, and it stays an aside.
            MessageMarkdown(
                text,
                bodyFont: ClientType.caption,
                codeFont: Theme.monoText(10, relativeTo: .caption),
                style: .aside,
                selectable: !isLive,
                cacheScope: "client-thinking",
                live: isLive,
                liveID: "\(markdownCacheID):\(item.id)"
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button(L10n.text("apple.clientchatrows.copy_reasoning.5d2976d8")) { ChatClipboard.copy(text) }
            }
        case let .tool(state) where item.plainStep == .detail:
            ChatStepDetail(step: .tool(state))
        case let .edit(state) where item.plainStep == .detail:
            ChatStepDetail(step: .edit(state))
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
                compact: compactTools || item.plainStep == .line
            )
        case let .edit(state):
            ChatFileEditRow(state: state, animatesRunning: animatesRunning, expandsOutput: expandsOutput, compact: compactTools || item.plainStep == .line)
        case let .group(group):
            ChatStepGroupRow(group: group, animatesRunning: animatesRunning) { toggleGroup(item.id) }
        case let .question(question):
            ChatQuestionCard(question: question, canAnswer: canAnswerQuestions, isSending: answeringQuestion) { text in
                answerQuestion(question, text)
            }
        case let .changes(changes):
            ChatTurnChangesCard(changes: changes, review: reviewChanges)
        case let .attachment(attachment):
            // Same as the Mac: stable identity across polls. The revision
            // still redraws through Equatable; recreating collapsed the row.
            ClientChatResponseAttachment(
                attachment: attachment, data: attachmentData,
                isLoading: attachmentIsLoading, downloadError: attachmentError,
                onDownload: { downloadAttachment(attachment) },
                onOpen: { data in openAttachment(attachment, data) }
            )
                .id(attachment.id)
        case let .handoff(to, brief):
            ClientChatHandoffRow(agent: agentLabel(to), brief: brief)
        case let .approval(approval):
            ClientChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        case let .usage(input, output, cost):
            HStack(spacing: Theme.Space.s) {
                Text(L10n.text("apple.clientchatrows.0_in_1_out.f48051a0", "\(input.formatted())", "\(output.formatted())"))
                if let cost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(ClientType.caption)
            .foregroundStyle(.secondary)
        case let .failed(text):
            if ChatAuthenticationFailure.isClaudeSignInRefusal(text) {
                Label(L10n.text("apple.agentsetup.history"), systemImage: "person.crop.circle.badge.key")
                    .font(Theme.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    PersonaMark(seed: faceSeed, size: 26, state: .failed)
                    Text(text)
                        .font(ClientType.label)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button(L10n.text("common.copy")) { ChatClipboard.copy(text) }
                        }
                }
            }
        }
    }
}

private struct ClientChatResponseAttachment: View {
    let attachment: ChatAttachment
    let data: Data?
    var isLoading: Bool
    var downloadError: String?
    var onDownload: () -> Void
    var onOpen: (Data) -> Void

    var body: some View {
        // One tappable card in every state, and it presents nothing itself.
        // It used to own both a Quick Look presentation and the staged copy
        // that presentation needed, from inside a lazy stack that is free to
        // tear a row down mid-tap, and it disabled itself the moment the bytes
        // arrived. A downloaded file was a grey rectangle, then a card that
        // did nothing at all. Opening is the chat view's job now; this is a
        // button.
        Button { if let data { onOpen(data) } else { onDownload() } } label: { content }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(
                data == nil ? L10n.text("apple.clientchatrows.download_0.465e0e80", "\(attachment.name)") : L10n.text("apple.clientchatrows.open_0.e71b4013", "\(attachment.name)")
            )
            .task(id: data) {
                guard let data, attachment.mediaType?.hasPrefix("image/") == true else { return }
                // SwiftUI restarts a row's task when it re-enters the viewport.
                // Keep its decoded image and geometry on those appearances.
                guard decodedData != data else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
                guard !Task.isCancelled else { return }
                decodedData = data
                decodedImage = result
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let aspect = imageAspect {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .clipped()
                    .background(Theme.background)
            }
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if data == nil {
                    ActionIcon.download.label(downloadError == nil ? L10n.text("apple.clientchatrows.download.d6eafe82") : L10n.text("common.retry"))
                        .font(ClientType.label)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                } else {
                    ActionIcon.preview.label(L10n.text("common.open"))
                        .font(ClientType.label)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    @State private var decodedImage: UIImage?
    @State private var decodedData: Data?
    // Header metadata is available before the async task starts, so the first
    // layout already has the final image box. Pixels only paint its overlay.
    private var imageAspect: CGFloat? {
        guard let data, attachment.mediaType?.hasPrefix("image/") == true else { return nil }
        return ClientChatImageDims.aspect(of: data)
    }

    private var image: UIImage? { decodedData == data ? decodedImage : nil }

    private var detail: String {
        if let downloadError { return downloadError }
        let type = attachment.mediaType ?? L10n.text("apple.clientchatrows.file.50009ce1")
        guard let size = attachment.size else { return type }
        return "\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private var symbol: String {
        let type = attachment.mediaType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("video/") { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") || type.contains("json") { return "doc.text" }
        return "doc"
    }

}

/// Image dimensions from the file header, without decoding pixels. Used to
/// reserve an attachment row's frame before its image arrives, so the decode
/// landing shifts no layout mid-scroll.
private enum ClientChatImageDims {
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

/// The point where a conversation changed hands, and what the incoming agent
/// was told. Same promise as the Mac: the summary is disclosed, never hidden.
struct ClientChatHandoffRow: View {
    let agent: String
    let brief: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(L10n.text("apple.clientchatrows.handed_to_0.902d7234", "\(agent)"))
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                if !brief.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? L10n.text("apple.clientchatrows.hide.ac20a57b") : L10n.text("apple.clientchatrows.what_it_was_told.4b2128b2"))
                            Image(systemName: "chevron.right")
                                .font(Theme.font(9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded {
                Text(brief)
                    .font(ClientType.code)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.clientchatrows.handed_to_0_with_a_summary_of_the_conversa.136c6fc3", "\(agent)"))
    }
}

struct ClientChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: outcome.symbol)
                    .foregroundStyle(outcome.tint)
                Text(outcome.title)
                    .font(ClientType.label.weight(.semibold))
                Spacer(minLength: Theme.Space.s)
                if isPending, let remaining = remainingText {
                    Text(remaining)
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(L10n.text("apple.clientchatrows.0_left_to_answer.63343d2a", "\(remaining)"))
                }
                Text(SeatStep.approvalWord(verb: approval.verb, pending: isPending))
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(outcome.tint.opacity(0.12), in: Capsule())
            }
            Text(approval.preview)
                .font(ClientType.code)
                .textSelection(.enabled)
                .lineLimit(5)
            if isPending {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { actions }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { actions }
                }
                if let note = SeatStep.allowAlwaysNote(verb: approval.verb, shellPrefix: approval.shellPrefix) {
                    Text(note)
                        .font(ClientType.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(outcome.detail)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder private var actions: some View {
        Button(L10n.text("apple.clientchatrows.allow.e213c161"), .allow) { resolve(approval, "allow") }
            .buttonStyle(AccentButtonStyle(small: true))
        Button(L10n.text("apple.clientchatrows.always_allow.977618bd"), .allow) { resolve(approval, "allowAlways") }
            .buttonStyle(SecondaryButtonStyle(small: true))
        Button(L10n.text("apple.clientchatrows.deny.05a2d733"), .deny, role: .destructive) { resolve(approval, "deny") }
            .buttonStyle(DestructiveButtonStyle(small: true))
    }
}

/// Compared by value so a transcript can skip a row that did not move.
///
/// Same rule as `ChatEventRow`: a global attachment revision must not rebuild
/// every markdown row when one file arrives. Only an attachment card looks at
/// loading, error, and whether bytes are present.
extension ClientChatEventRow: Equatable {
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

#endif
