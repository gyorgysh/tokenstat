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

/// Every pull request a chat opened or talked about.
struct ChatPullList: View {
    let pulls: [ChatPull]
    let open: (ChatPull) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pulls) { pull in
                Button { open(pull) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pull.title)
                            .font(Theme.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ChatPullSummaryLine(pull: pull)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
    }
}

/// `Merged · owner/repo #53   +1839 −1391`
struct ChatPullSummaryLine: View {
    let pull: ChatPull

    var body: some View {
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
}

/// Asked when a pull request is opened. The answer is kept only when the
/// person says so.
struct PullOpenSheet: View {
    let pull: ChatPull
    let choose: (PullOpenPreference.Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remember = false

    var body: some View {
        ThemedSheet(title: L10n.text("common.pulls.open_title"),
                    subtitle: L10n.text("common.pulls.open_subtitle"), icon: .merge,
                    onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(pull.title)
                    .font(Theme.callout.weight(.medium))
                    .lineLimit(2)
                ChatPullSummaryLine(pull: pull)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L10n.text("common.pulls.open_remember"), isOn: $remember)
                        .toggleStyle(.brandCheckbox)
                        .font(Theme.callout)
                    Text(rememberHelp)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                }
                .padding(.top, Theme.Space.s)
            }
        } actions: {
            #if os(macOS)
            Spacer(minLength: 0)
            #endif
            Button(L10n.text("common.pulls.open_browser"), .external) { pick(.browser) }
                .buttonStyle(SecondaryButtonStyle())
            Button(L10n.text("common.pulls.view_here"), .source) { pick(.here) }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        #if os(macOS)
        .modalFrame(width: 460, height: 324)
        #else
        .presentationDetents([.medium])
        #endif
    }

    /// The setting sits in a different place on each.
    private var rememberHelp: String {
        #if os(macOS)
        L10n.text("apple.pulls.open_remember_help")
        #else
        L10n.text("common.pulls.open_remember_help")
        #endif
    }

    private func pick(_ choice: PullOpenPreference.Choice) {
        // The presenter moves on from here. Dismissing as well would race it
        // when the next thing is another sheet.
        if remember { PullOpenPreference.shared.choice = choice }
        choose(choice)
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
/// The row's mark, with the list beside it while the pointer rests on either,
/// or after a click until it is dismissed.
struct SidebarChatPullMark: View {
    let pulls: [ChatPull]
    let open: (ChatPull) -> Void
    @State private var showing = false
    @State private var held = false
    @State private var overMark = false
    @State private var overCard = false

    /// What the mark takes up in a row, for the row to leave room for.
    static func label(_ pulls: [ChatPull]) -> some View {
        ChatPullMark(pulls: pulls, size: DisplayFit.dp(13), font: Theme.fit(11))
            .padding(.vertical, 4)
            .contentShape(.rect)
    }

    var body: some View {
        Button {
            held = !(held && showing)
            showing = held
        } label: { Self.label(pulls) }
            .buttonStyle(.plain)
            .onHover { overMark = $0 }
            .task(id: overMark || overCard) {
                // A pause before opening, so crossing the list does not flash
                // cards, and one before closing, so the pointer can get there.
                do { try await Task.sleep(for: .milliseconds(overMark || overCard ? 250 : 200)) } catch { return }
                showing = held || overMark || overCard
            }
            .onChange(of: showing) { _, shown in
                if !shown { held = false }
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

/// Where a chat row left room for its mark. The mark itself sits over the row,
/// because a control inside the row's own button never gets its click.
struct SidebarPullMarkSeat: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
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

/// Where a chat's pull request opens, in both Apple settings surfaces.
struct PullOpenPicker: View {
    @State private var preference = PullOpenPreference.shared

    var body: some View {
        #if os(macOS)
        HStack(spacing: Theme.Space.m) {
            Text(L10n.text("common.pulls.open_in"))
                .font(Theme.callout)
            Spacer(minLength: Theme.Space.s)
            SegmentedCapsulePicker(
                options: PullOpenPreference.Choice.allCases.map {
                    (value: $0, label: PullOpenPreference.label($0), symbol: "")
                },
                selection: $preference.choice
            )
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("common.pulls.open_in"))
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("common.pulls.open_in"), mark: "mark_chat")
            SegmentedTabs(options: PullOpenPreference.Choice.allCases, selection: $preference.choice,
                          title: PullOpenPreference.label, comfortable: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("common.pulls.open_in"))
        #endif
    }
}
