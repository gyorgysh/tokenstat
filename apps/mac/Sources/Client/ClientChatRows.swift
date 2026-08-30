// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// Phone-sized transcript blocks. Assistant prose and tools are the same
/// views as the Mac. Edits use `DiffLineRow` so a hunk does not spend a
/// quarter of the screen on two gutters.
struct ClientChatEventRow: View {
    let item: ChatDisplayItem
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 36)
                Text(text)
                    .font(ClientType.body)
                    .padding(Theme.Space.m)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case let .assistant(text):
            MarkdownText(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .thinking(text):
            Text(text)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            ClientChatEditRow(path: path, added: added, removed: removed, patch: patch)
        case let .approval(approval):
            ClientChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        case let .usage(input, output, cost):
            HStack(spacing: Theme.Space.s) {
                Text("\(input.formatted()) in · \(output.formatted()) out")
                if let cost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(ClientType.caption)
            .foregroundStyle(.secondary)
        case let .failed(text):
            Text(text)
                .font(ClientType.label)
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ClientChatEditRow: View {
    let path: String
    let added: UInt32
    let removed: UInt32
    let patch: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "square.and.pencil")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(path)
                    .font(ClientType.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("+\(added)")
                    .font(ClientType.rowFigure)
                    .foregroundStyle(Theme.diffAdded)
                Text("−\(removed)")
                    .font(ClientType.rowFigure)
                    .foregroundStyle(Theme.diffRemoved)
                Spacer(minLength: 0)
                if !patch.isEmpty {
                    Button(expanded ? "Hide edit" : "Show edit", .preview) {
                        expanded.toggle()
                    }
                    .clientGlassStyle()
                    .controlSize(.small)
                }
            }
            if expanded, !patch.isEmpty {
                let diff = FileDiff.fromEditPatch(path: path, patch: patch)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            ForEach(hunk.lines) { line in
                                DiffLineRow(line: line, minWidth: 0)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

struct ClientChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.accent)
                Text(isPending ? "Permission needed" : "Permission answered")
                    .font(ClientType.label.weight(.semibold))
                Spacer()
                Text(approval.verb)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
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
            } else {
                Text("This request is no longer waiting.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isPending ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Allow", .allow) { resolve(approval, "allow") }
            .buttonStyle(SecondaryButtonStyle(small: true))
        Button("Always allow", .allow) { resolve(approval, "allowAlways") }
            .buttonStyle(AccentButtonStyle(small: true))
        Button("Deny", .deny, role: .destructive) { resolve(approval, "deny") }
            .buttonStyle(SecondaryButtonStyle(small: true))
    }
}

#endif
