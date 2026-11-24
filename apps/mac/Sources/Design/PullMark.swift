// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A pull request's state as a small branch drawing: two commits and a line
/// for all of them, then what became of it. Drawn rather than borrowed, so the
/// three states share one weight at sidebar size.
struct PullGlyph: Shape {
    let state: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        func dot(_ x: CGFloat, _ y: CGFloat) {
            let r = 1.75 * scale, c = at(x, y)
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func line(_ points: [CGPoint]) { path.addLines(points) }
        dot(4, 3.5)
        dot(4, 12.5)
        line([at(4, 5.25), at(4, 10.75)])
        switch state {
        case "merged":
            dot(12, 9)
            path.move(to: at(4, 5.25))
            path.addCurve(to: at(10.25, 9), control1: at(4.2, 7.6), control2: at(6.8, 9))
        case "closed":
            dot(12, 12.5)
            line([at(12, 7.75), at(12, 10.75)])
            line([at(10.2, 1.9), at(13.8, 5.5)])
            line([at(13.8, 1.9), at(10.2, 5.5)])
        default:
            dot(12, 12.5)
            path.move(to: at(8.25, 3.5))
            path.addLine(to: at(10.25, 3.5))
            path.addQuadCurve(to: at(12, 5.25), control: at(12, 3.5))
            path.addLine(to: at(12, 10.75))
            line([at(10.1, 1.4), at(8, 3.5), at(10.1, 5.6)])
        }
        return path
    }
}

struct PullGlyphView: View {
    let state: String
    let tint: Color
    var size: CGFloat = 13

    var body: some View {
        PullGlyph(state: state)
            .stroke(tint, style: StrokeStyle(lineWidth: size * 1.35 / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// The mark on a chat row: the state, and how many when there are several.
struct ChatPullMark: View {
    let pulls: [ChatPull]
    var size: CGFloat = 13
    var font: Font = Theme.numeric(11)

    var body: some View {
        if let lead = ChatPull.lead(of: pulls) {
            HStack(spacing: 3) {
                PullGlyphView(state: lead.state, tint: lead.tint, size: size)
                if pulls.count > 1 {
                    Text("\(pulls.count)").font(font).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pulls.map { L10n.text("apple.branchpull.chip", "\($0.number)", $0.stateLabel) }.joined(separator: ", "))
        }
    }
}

/// Every pull request a chat opened or talked about. A row opens it here, and
/// the button beside it opens the forge's own page.
struct ChatPullList: View {
    let pulls: [ChatPull]
    let open: (ChatPull) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pulls, id: \.url) { pull in
                HStack(spacing: 0) {
                    Button { open(pull) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pull.title)
                                .font(Theme.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                PullGlyphView(state: pull.state, tint: pull.tint, size: 12)
                                Text(pull.stateLabel).foregroundStyle(pull.tint)
                                Text(verbatim: "·").foregroundStyle(.tertiary)
                                Text(verbatim: pull.name).foregroundStyle(.secondary)
                                Spacer(minLength: Theme.Space.m)
                                if let additions = pull.additions, let deletions = pull.deletions {
                                    Text(verbatim: "+\(additions)").foregroundStyle(Theme.diffAdded)
                                    Text(verbatim: "−\(deletions)").foregroundStyle(Theme.diffRemoved)
                                }
                            }
                            .font(Theme.numeric(11))
                            .lineLimit(1)
                        }
                        .padding(.vertical, 7)
                        .padding(.leading, Theme.Space.m)
                        .padding(.trailing, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if let url = pull.webURL {
                        Button { openURL(url) } label: {
                            ActionIcon.external.label(L10n.text("apple.branchpull.open_browser"))
                                .labelStyle(.iconOnly)
                                .font(Theme.fit(11))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 32)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("apple.branchpull.open_browser"))
                        .padding(.trailing, Theme.Space.s)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

extension ChatPull {
    var tint: Color {
        if draft, state == "open" { return Theme.stateIdle }
        switch state {
        case "merged": return Theme.pullMerged
        case "closed": return Theme.pullClosed
        default: return Theme.pullOpen
        }
    }
}

#if os(macOS)
/// The row's mark, with the list beside it while the pointer rests on either.
struct SidebarChatPullMark: View {
    let pulls: [ChatPull]
    let open: (ChatPull) -> Void
    @State private var showing = false
    @State private var overMark = false
    @State private var overCard = false

    var body: some View {
        ChatPullMark(pulls: pulls, size: DisplayFit.dp(13), font: Theme.fit(11))
            .padding(.vertical, 4)
            .contentShape(.rect)
            .onHover { overMark = $0 }
            .task(id: overMark || overCard) {
                // A pause before opening, so crossing the list does not flash
                // cards, and one before closing, so the pointer can get there.
                do { try await Task.sleep(for: .milliseconds(overMark || overCard ? 250 : 200)) } catch { return }
                showing = overMark || overCard
            }
            .onChange(of: SidebarMenuTracking.shared.active) { _, active in
                if active { showing = false }
            }
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                ChatPullList(pulls: pulls) { pull in
                    showing = false
                    open(pull)
                }
                    .frame(width: 380)
                    .onHover { overCard = $0 }
                    .onDisappear { overCard = false }
            }
    }
}
#endif

#if os(iOS)
/// One pull request over the chat it was mentioned in.
struct ClientPullSheet: View {
    let pull: ChatPull
    let peer: String
    let workspaceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var model = PullDetailModel()

    var body: some View {
        NavigationStack {
            PullDetailView(workspaceID: workspaceID, peer: peer, summary: PullSummary(pull), scope: nil,
                           onBack: { dismiss() }, model: model)
        }
        .onDisappear { model.prepareForCache() }
    }
}
#endif
