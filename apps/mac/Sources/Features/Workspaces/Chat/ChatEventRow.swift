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

/// A decision stays where the agent stopped, so the person can see the tool,
/// its target and the surrounding response without losing their reading place.
struct ChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.accent)
                Text(isPending ? "Permission needed" : "Permission answered")
                    .font(Theme.callout.weight(.semibold))
                Spacer()
                Text(approval.verb)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
            }
            Text(approval.preview)
                .font(Theme.monoText(11))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .lineLimit(4)
            if isPending {
                HStack(spacing: Theme.Space.s) {
                    Button("Allow", .allow) { resolve(approval, "allow") }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button("Always allow", .allow) { resolve(approval, "allowAlways") }
                        .buttonStyle(AccentButtonStyle(small: true))
                    Button("Deny", .deny, role: .destructive) { resolve(approval, "deny") }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            } else {
                Label("This request is no longer waiting.", systemImage: ActionIcon.allow.symbol)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isPending ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
    }
}
