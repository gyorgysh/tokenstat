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

    var body: some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(Theme.body)
                    .padding(Theme.Space.m)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case let .assistant(text, backend):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(backend.map(agentLabel) ?? defaultAgentName, systemImage: "sparkles")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                MarkdownText(text)
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
            Text(text)
                .font(Theme.caption)
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
            Text(text)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            let url = directory.appendingPathComponent(attachment.name)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
        #endif
    }
}

/// A lightweight streaming cue that sits at the same left edge as an agent
/// reply. It makes an in-progress turn feel like a conversation without
/// reserving the visual weight of another card.
struct ChatWorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? (index == 1 ? 1 : 0.42) : (index == 1 ? 0.42 : 1))
            }
            Text("Working")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .accessibilityLabel("Assistant is working")
    }
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
