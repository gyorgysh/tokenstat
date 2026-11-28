// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ChatEventRow: View {
    let item: ChatDisplayItem
    let defaultAgentName: String
    let agentLabel: (String) -> String
    let attachmentData: Data?
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    var attachmentFile: URL? = nil
    var imageResources: [ChatImageResource] = []
    var attachmentIsLoading = false
    var attachmentError: String?
    var downloadAttachment: (ChatAttachment) -> Void = { _ in }
    var canOpenAttachment: () -> Bool = { false }
    var faceSeed: UInt64 = 0
    var isLive = false
    @State private var markdownCacheID = UUID().uuidString
    var animatesRunning = true
    var expandsOutput = false
    var compactTools = false
    var toggleGroup: (String) -> Void = { _ in }
    var answerQuestion: (ChatQuestion, String) -> Void = { _, _ in }
    var answeringQuestion = false
    var canAnswerQuestions = true
    var reviewChanges: ((String?) -> Void)? = nil
    var reviewTurnChanges: ((ChatTurnChanges, String?) -> Void)? = nil
    #if os(macOS)
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

    private var answerEdgeOpacity: Double {
        #if os(macOS)
        hovering && !isLive ? 1 : 0.72
        #else
        0.72
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            content
                .chatStepBacking(item.isPlainStep)
            if !galleryResources.isEmpty {
                ChatImageGallery(resources: galleryResources, compact: compactGallery)
            }
        }
        .modifier(ChatGroupStepInset(nested: item.groupID != nil))
    }

    private var compactGallery: Bool { if case .attachment = item.kind { return false }; return true }
    private var galleryResources: [ChatImageResource] {
        if !imageResources.isEmpty { return imageResources }
        if case let .attachment(file) = item.kind, file.mediaType?.hasPrefix("image/") == true {
            return [ChatImageResource(attachment: file, data: attachmentData, file: attachmentFile,
                                     loading: attachmentIsLoading, error: attachmentError)]
        }
        return []
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case let .user(text):
            #if os(macOS)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Spacer(minLength: 48)
                RowCopyButton(text: text, help: L10n.text("apple.chateventrow.copy_prompt.ffc64b8b"), visible: hovering)
                userBubble(text, selectable: allowsSelection, steer: item.isSteer)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #else
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Spacer(minLength: 48)
                userBubble(text, selectable: allowsSelection, steer: item.isSteer)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            #endif
        case let .assistant(text, backend):
            let reply = item.part?.reply ?? text
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if item.part?.isFirst ?? true {
                    #if os(macOS)
                    HStack(spacing: Theme.Space.s) {
                        Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                        RowCopyButton(text: reply, help: L10n.text("apple.chateventrow.copy_response.f0f755af"), visible: hovering)
                    }
                    #else
                    HStack(spacing: Theme.Space.s) {
                        Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                        RowCopyButton(text: reply, help: L10n.text("apple.chateventrow.copy_response.f0f755af"))
                    }
                    #endif
                }
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
            .modifier(ReplyCardChrome(part: item.part, edgeOpacity: item.part == nil ? answerEdgeOpacity : 0.72))
            #if os(macOS)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #endif
            .contextMenu {
                Button(L10n.text("apple.chateventrow.copy_response.f0f755af")) { ChatClipboard.copy(reply) }
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
        case let .plan(steps):
            ChatPlanCard(steps: steps, live: animatesRunning)
        case let .changes(changes):
            ChatTurnChangesCard(changes: changes, review: reviewTurnChanges.map { callback in
                { path in callback(changes, path) }
            } ?? reviewChanges, reviewHelp: reviewTurnChanges == nil ? nil : L10n.text("apple.workbench.recorded_edits"))
        case let .attachment(attachment) where attachment.mediaType?.hasPrefix("image/") == true:
            EmptyView()
        case let .attachment(attachment):
            ChatResponseAttachment(
                attachment: attachment, data: attachmentData, file: attachmentFile,
                isLoading: attachmentIsLoading, downloadError: attachmentError,
                onDownload: { downloadAttachment(attachment) }, canOpen: canOpenAttachment
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
                    PersonaMark(seed: faceSeed, size: 26, state: .failed, settlesAfter: 4)
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
private func userBubble(_ text: String, selectable: Bool, steer: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.xs) {
        if steer {
            Label(L10n.text("common.chat.steer"), systemImage: "arrow.triangle.branch")
                .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                .help(L10n.text("common.chat.steer_help"))
        }
        Text(text)
            .font(Theme.chatBody)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(SelectableWhen(selectable))
    }
        .padding(Theme.Space.m)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button(L10n.text("common.copy")) { ChatClipboard.copy(text) }
        }
}

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

func diffColoredText(_ patch: String, lineLimit: Int, clipLongLines: Bool = true) -> (text: AttributedString, cut: Int) {
    var out = AttributedString()
    var shown = 0
    var total = 0
    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        total += 1
        guard shown < lineLimit else { continue }
        shown += 1
        var line = AttributedString((clipLongLines ? ChatToolState.clip(String(raw)) : String(raw)) + "\n")
        line.foregroundColor =
            (raw.hasPrefix("+") && !raw.hasPrefix("+++")) ? Theme.diffAdded
            : (raw.hasPrefix("-") && !raw.hasPrefix("---")) ? Theme.diffRemoved
            : raw.hasPrefix("@@") ? Color.secondary
            : Color.primary
        out += line
    }
    return (out, total - shown)
}

enum ChatImageDims {
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

    static func aspect(of file: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? height / width : width / height
    }
}

private struct ChatResponseAttachment: View {
    let attachment: ChatAttachment
    let data: Data?
    let file: URL?
    var isLoading: Bool
    var downloadError: String?
    var onDownload: () -> Void
    var canOpen: () -> Bool
    @State private var hovering = false
    @State private var opening: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if (file != nil || data != nil), ClientChatModelPreview.canPreview(attachment.name) {
                ClientChatModelPreview(name: attachment.name, id: attachment.id, data: data, file: file)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        Button(action: data == nil && file == nil ? onDownload : open) {
            VStack(alignment: .leading, spacing: 0) {
                if let file, attachment.mediaType?.hasPrefix("video/") == true { ChatVideoPreview(file: file) }
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
                    if isLoading || opening != nil {
                        ProgressView().controlSize(.small)
                    } else if data == nil && file == nil {
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
        .disabled(isLoading || opening != nil)
        .onHover { hovering = $0 }
        .help(data == nil && file == nil ? L10n.text("apple.chateventrow.download_0.465e0e80", "\(attachment.name)") : L10n.text("apple.chateventrow.open_0.e71b4013", "\(attachment.name)"))
        }
        .onChange(of: imageSource) { _, _ in opening = nil }
        .onChange(of: attachment) { _, _ in opening = nil }
        .onDisappear { opening = nil }
        .task(id: opening) {
            #if os(macOS)
            guard let ticket = opening, let data else { return }
            defer { if opening == ticket { opening = nil } }
            do {
                let url = try await ChatFileStaging.prepare(data, id: attachment.id, name: attachment.name,
                                                           canUse: { canFinishOpening(ticket) })
                guard !Task.isCancelled, canFinishOpening(ticket) else { return }
                if !NSWorkspace.shared.open(url) { NSSound.beep() }
                Task { await ChatAttachmentCache.shared.maintain() }
            } catch is CancellationError {
            } catch {
                if canFinishOpening(ticket) { NSSound.beep() }
            }
            #endif
        }
        .task(id: imageSource) {
            guard attachment.mediaType?.hasPrefix("image/") == true else { return }
            let source = imageSource
            guard decodedSource != source else { return }
            let thumbnail = await Task.detached(priority: .userInitiated) {
                if let data = source.data { return ChatThumbnail.make(from: data, maxPixel: 1440, preservingAlpha: true) }
                if let file = source.file { return ChatThumbnail.make(from: file, maxPixel: 1440, preservingAlpha: true) }
                return nil
            }.value
            guard !Task.isCancelled, let thumbnail else { return }
            decodedSource = source
            #if os(macOS)
            decodedImage = NSImage(data: thumbnail).map { Image(nsImage: $0) }
            #else
            decodedImage = UIImage(data: thumbnail).map { Image(uiImage: $0) }
            #endif
        }
    }

    private struct ImageSource: Hashable {
        let data: Data?
        let file: URL?
    }
    private var imageSource: ImageSource { ImageSource(data: data, file: file) }
    @State private var decodedImage: Image?
    @State private var decodedSource: ImageSource?

    private var imageAspect: CGFloat? {
        guard attachment.mediaType?.hasPrefix("image/") == true else { return nil }
        if let data { return ChatImageDims.aspect(of: data) }
        if let file { return ChatImageDims.aspect(of: file) }
        return nil
    }

    private var image: Image? {
        decodedSource == imageSource ? decodedImage : nil
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
        if type.hasPrefix("model/") || ClientChatModelPreview.canPreview(attachment.name) { return "cube" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") || type.contains("json") { return "doc.text" }
        return "doc"
    }

    private func canFinishOpening(_ ticket: UUID) -> Bool {
        opening == ticket && canOpen()
    }

    private func open() {
        #if os(macOS)
        guard opening == nil, canOpen() else { return }
        if let file {
            if !NSWorkspace.shared.open(file) { NSSound.beep() }
            return
        }
        guard data != nil else { return }
        opening = UUID()
        #endif
    }
}

struct ChatWorkingIndicator: View {
    var seed: UInt64
    var mood: PersonaMood = .thinking
    var step: String? = nil
    var startedAt: Date? = nil
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ZStack {
                if !reduceMotion, mood == .thinking || mood == .waiting {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                }
                Group {
                    if mood == .thinking {
                        PersonaPastime(seed: seed, size: 26, doing: .thought, pokeable: false)
                    } else {
                        PersonaMark(seed: seed, size: 26, state: mood)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(width: 30, height: 30)
            .environment(\.personaMotionAllowed, !still)
            .transaction { $0.animation = nil }
            HStack(spacing: 6) {
                SeatLivePhrase(mood: mood, step: step, animate: !reduceMotion && !still)
                    .layoutPriority(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let startedAt {
                    TurnElapsedClock(since: startedAt)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .chatStepBacking()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TranscriptFollow.seatHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct SeatLivePhrase: View {
    var mood: PersonaMood
    var step: String?
    var animate: Bool
    @State private var phraseIndex = 0

    private var text: String {
        if mood == .working, let step, !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return step
        }
        if mood == .thinking {
            let phrases = SeatStep.thinkingPhrases
            guard !phrases.isEmpty else { return mood.label }
            return phrases[phraseIndex % phrases.count]
        }
        return mood.label
    }

    var body: some View {
        Text(text)
            .font(Theme.font(13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .contentTransition(.interpolate)
            .overlay { if animate { SeatShimmer(text: text) } }
            .animation(morphAnimation, value: text)
            .onChange(of: mood) { _, _ in
                phraseIndex = 0
            }
            .task(id: mood) {
                guard mood == .thinking, animate else { return }
                let phrases = SeatStep.thinkingPhrases
                guard phrases.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 4400...5600)))
                    guard !Task.isCancelled, mood == .thinking else { return }
                    withAnimation(morphAnimation) {
                        phraseIndex = (phraseIndex + 1) % phrases.count
                    }
                }
            }
    }

    private var morphAnimation: Animation {
        animate ? .easeInOut(duration: 0.7) : .linear(duration: 0)
    }
}

private struct SeatShimmer: View {
    var text: String
    private let period: Double = 2.6

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let band = max(geo.size.width * 0.45, 40)
                let travel = geo.size.width + band * 2
                LinearGradient(
                    colors: [.clear, .white.opacity(0.55), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + travel * t)
            }
        }
        .mask(Text(text).font(Theme.font(13, weight: .medium)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TurnElapsedClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(TurnElapsed.phrase(since: since, now: context.date))
                .font(Theme.font(12, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(TurnElapsed.durationWords(since: since, now: context.date))
        }
    }
}

struct ChatHandoffRow: View {
    let agent: String
    let brief: String

    var body: some View {
        ChatHandoffBanner(agent: agent, brief: brief)
    }
}

struct ChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    private var canRespond: Bool { isPending && !approval.readOnly }
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
                if canRespond, let remaining = remainingText {
                    Text(remaining)
                        .font(Theme.numeric(11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(L10n.text("apple.chateventrow.0_left_to_answer.63343d2a", "\(remaining)"))
                }
                Text(SeatStep.approvalWord(verb: approval.verb, pending: canRespond))
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
            if canRespond {
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
                    canRespond ? outcome.tint.opacity(0.55) : Theme.border,
                    lineWidth: canRespond ? 1.5 : 1
                )
        }
        .task(id: canRespond) {
            guard canRespond else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var outcome: ChatApprovalOutcome {
        ChatApprovalOutcome(approval: approval, isPending: canRespond)
    }

    private var remainingText: String? {
        let seconds = Int((Double(approval.expiresAtMs) / 1000 - now.timeIntervalSince1970).rounded())
        guard seconds > 0 else { return nil }
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct ChatApprovalActions: View {
    let approval: ChatApproval
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        FlowLayout(spacing: Theme.Space.s, rowSpacing: Theme.Space.s) {
            Button(L10n.text("common.chat.approval.allow_once"), .allow) { resolve(approval, "allow") }
                .buttonStyle(AccentButtonStyle(small: true))
                .keyboardShortcut(.return, modifiers: [.command])
            if !SeatStep.isShell(verb: approval.verb) || approval.shellPrefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Button(L10n.text("apple.chateventrow.always_allow.977618bd"), .allow) { resolve(approval, "allowAlways") }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            Button(L10n.text("apple.chateventrow.deny.05a2d733"), .deny, role: .destructive) { resolve(approval, "deny") }
                .buttonStyle(DestructiveButtonStyle(small: true))
        }
    }
}

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

extension ChatEventRow: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item
            && lhs.defaultAgentName == rhs.defaultAgentName
            && lhs.isLive == rhs.isLive
            && lhs.animatesRunning == rhs.animatesRunning
            && lhs.expandsOutput == rhs.expandsOutput
            && lhs.compactTools == rhs.compactTools
            && (lhs.reviewChanges == nil) == (rhs.reviewChanges == nil)
            && (lhs.reviewTurnChanges == nil) == (rhs.reviewTurnChanges == nil)
            && lhs.imageResources == rhs.imageResources
        else { return false }
        switch lhs.item.kind {
        case .attachment:
            return lhs.attachmentIsLoading == rhs.attachmentIsLoading
                && lhs.attachmentError == rhs.attachmentError
                && (lhs.attachmentData == nil) == (rhs.attachmentData == nil)
                && lhs.attachmentFile == rhs.attachmentFile
        case .question:
            return lhs.answeringQuestion == rhs.answeringQuestion
                && lhs.canAnswerQuestions == rhs.canAnswerQuestions
        case .approval:
            return lhs.isPending == rhs.isPending
        case .failed:
            return lhs.faceSeed == rhs.faceSeed
        default:
            return true
        }
    }
}


struct ReplyCardChrome: ViewModifier {
    let part: ChatReplyPart?
    let edgeOpacity: Double

    func body(content: Content) -> some View {
        let top = part?.isFirst ?? true
        let bottom = part?.isLast ?? true
        content
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, top || part?.gapBefore == true ? Theme.Space.m : 0)
            .padding(.bottom, bottom ? Theme.Space.m : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.72), in: ReplyCardShape(top: top, bottom: bottom))
            .overlay {
                ReplyCardEdge(top: top, bottom: bottom)
                    .stroke(Theme.border.opacity(edgeOpacity), lineWidth: 1)
                #if os(macOS)
                    .animation(Motion.hover, value: edgeOpacity)
                #endif
            }
            .padding(.top, top ? 0 : -Theme.Space.m)
    }
}

struct ReplyCardShape: Shape {
    var top: Bool
    var bottom: Bool
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0,
            topTrailingRadius: top ? radius : 0,
            style: .continuous
        ).path(in: rect)
    }
}

struct ReplyCardEdge: Shape {
    var top: Bool
    var bottom: Bool
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        let topY = top ? r.minY + radius : rect.minY - 0.5
        let bottomY = bottom ? r.maxY - radius : rect.maxY + 0.5
        path.move(to: CGPoint(x: r.minX, y: topY))
        path.addLine(to: CGPoint(x: r.minX, y: bottomY))
        if bottom {
            path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius), control: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            path.move(to: CGPoint(x: r.maxX, y: bottomY))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: topY))
        if top {
            path.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
            path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + radius), control: CGPoint(x: r.minX, y: r.minY))
        }
        return path
    }
}
