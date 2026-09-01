// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One coalesced transcript block: a user turn, assistant markdown, a tool,
/// an edit, an approval, or a quiet usage line.
struct ChatEventRow: View {
    let item: ChatDisplayItem
    let defaultAgentName: String
    let agentLabel: (String) -> String
    let attachmentData: Data?
    let attachmentRevision: UInt64
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    /// The conversation's face, used when a turn fails so the same character
    /// that was thinking is the one that droops.
    var faceSeed: UInt64 = 0

    var body: some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(Theme.chatBody)
                    .padding(Theme.Space.m)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case let .assistant(text, backend):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                MarkdownText(text, bodyFont: Theme.chatBody, codeFont: Theme.chatCode)
                    .textSelection(.enabled)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.border.opacity(0.72), lineWidth: 1)
            }
        case let .turnSeparator(backend):
            HStack(spacing: Theme.Space.s) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                Text("\(agentLabel(backend)) · new turn")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
            .accessibilityLabel("New turn with \(agentLabel(backend))")
        case let .thinking(text):
            // Agents write their reasoning in markdown like everything else,
            // so a plain Text left `##` and `**` on screen as punctuation.
            // Quiet headings, because this is an aside and has to keep
            // reading as one.
            MarkdownText(
                text,
                bodyFont: Theme.caption,
                codeFont: Theme.monoText(10, relativeTo: .caption),
                style: .aside
            )
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        case let .tool(state):
            ToolRow(
                verb: state.verb,
                arg: state.target,
                snippet: state.snippet,
                time: state.duration,
                running: state.running,
                failed: state.failed
            )
        case let .edit(path, added, removed, patch):
            ChatEditRow(path: path, added: added, removed: removed, patch: patch)
        case let .attachment(attachment):
            ChatResponseAttachment(attachment: attachment, data: attachmentData)
                .id("\(attachment.id)-\(attachmentRevision)")
        case let .handoff(to, brief):
            ChatHandoffRow(agent: agentLabel(to), brief: brief)
        case let .approval(approval):
            ChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        case let .usage(input, output, cost):
            HStack(spacing: Theme.Space.s) {
                Text("\(input.formatted()) in · \(output.formatted()) out")
                if let cost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
        case let .failed(text):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                PersonaMark(seed: faceSeed, size: 26, state: .failed)
                Text(text)
                    .font(Theme.callout)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A response file is part of the conversation, not a path printed into it.
/// Images get a useful inline preview; every other type gets the same compact
/// openable file card. Data came through the owning host, so this also works
/// for chats running on another paired machine.
private struct ChatResponseAttachment: View {
    let attachment: ChatAttachment
    let data: Data?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
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
                    if data == nil {
                        ProgressView().controlSize(.small)
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
        .disabled(data == nil)
        .onHover { hovering = $0 }
        .help(data == nil ? "Loading attachment" : "Open \(attachment.name)")
    }

    private var image: Image? {
        guard attachment.mediaType?.hasPrefix("image/") == true, let data else { return nil }
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    private var fileDetail: String {
        let kind = attachment.mediaType ?? "File"
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-chat-files", isDirectory: true)
            .appendingPathComponent(attachment.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = Self.sanitizedFileName(attachment.name)
            let url = directory.appendingPathComponent(safeName)
            // `attachment.name` comes from agent output and may contain
            // `../` or absolute paths. Ensure the resolved path stays inside
            // the per-attachment directory.
            guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else {
                NSSound.beep()
                return
            }
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
        #endif
    }

    /// Strip directory components, control characters, and empty results.
    static func sanitizedFileName(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        let cleaned = leaf.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: \.properties.isDefaultIgnorableCodePoint) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutNulls = cleaned.replacingOccurrences(of: "\0", with: "")
        if withoutNulls.isEmpty || withoutNulls == "." || withoutNulls == ".." {
            return "attachment"
        }
        // `lastPathComponent` already removed `/`, but keep a belt-and-suspenders
        // guard against any remaining separator.
        let noSeparators = withoutNulls.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return noSeparators.isEmpty ? "attachment" : noSeparators
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
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TranscriptFollow.seatHeight)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The mood names itself. One list, so a state added to the character
    /// cannot arrive in the transcript still calling itself "Thinking".
    private var label: String { mood.label }
}

/// Path and +n −m, expanding into the shared DiffBody rather than a second
/// renderer. The patch is a chat preview, not a git hunk.
private struct ChatEditRow: View {
    let path: String
    let added: UInt32
    let removed: UInt32
    let patch: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "square.and.pencil")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(path)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("+\(added)")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.diffAdded)
                Text("−\(removed)")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.diffRemoved)
                Spacer(minLength: 0)
                if !patch.isEmpty {
                    Button(expanded ? "Hide edit" : "Show edit", .preview) {
                        expanded.toggle()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            if expanded, !patch.isEmpty {
                ScrollView(.horizontal) {
                    DiffBody(diff: FileDiff.fromEditPatch(path: path, patch: patch))
                }
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
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
                Text("Handed to \(agent)")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                if !brief.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Hide summary" : "What it was told")
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
        .accessibilityLabel("Handed to \(agent), with a summary of the conversation so far")
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
                        .accessibilityLabel("\(remaining) left to answer")
                }
                Text(approval.verb)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(outcome.tint)
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
                if let prefix = approval.shellPrefix {
                    Text("Always allow remembers \(prefix) for this chat only.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Always allow remembers \(approval.verb) for this chat only.")
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
            Button("Allow", .allow) { resolve(approval, "allow") }
                .buttonStyle(AccentButtonStyle(small: true))
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Always allow", .allow) { resolve(approval, "allowAlways") }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Spacer(minLength: 0)
            Button("Deny", .deny, role: .destructive) { resolve(approval, "deny") }
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
                title: "Permission needed",
                detail: "",
                symbol: "hand.raised.fill",
                tint: Theme.accent
            )
        } else if approval.decision == "allow" {
            self.init(
                title: "Allowed",
                detail: "You allowed this and the agent went ahead.",
                symbol: ActionIcon.allow.symbol,
                tint: Theme.accent
            )
        } else if approval.decision == "deny" {
            self.init(
                title: "Denied",
                detail: "This was refused. The agent was told not to retry it.",
                symbol: ActionIcon.deny.symbol,
                tint: Theme.danger
            )
        } else {
            self.init(
                title: "Expired",
                detail: "Nobody answered in time, so the agent was refused.",
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
/// compared, and `attachmentData` is bytes: `attachmentRevision` is the model's
/// own answer to "did any of those bytes arrive", which is what this needs.
extension ChatEventRow: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.defaultAgentName == rhs.defaultAgentName
            && lhs.attachmentRevision == rhs.attachmentRevision
            && lhs.isPending == rhs.isPending
            && lhs.faceSeed == rhs.faceSeed
    }
}
