// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// One coalesced transcript block: a user turn, assistant markdown, a tool,
/// an edit, an approval, or a quiet usage line.
struct ChatEventRow: View {
    let item: ChatDisplayItem
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
        case let .assistant(text):
            MarkdownText(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(.footnote, design: .monospaced))
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
