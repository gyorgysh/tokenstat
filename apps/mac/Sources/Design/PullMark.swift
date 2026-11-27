// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

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

    private var rememberHelp: String {
        #if os(macOS)
        L10n.text("apple.pulls.open_remember_help")
        #else
        L10n.text("common.pulls.open_remember_help")
        #endif
    }

    private func pick(_ choice: PullOpenPreference.Choice) {
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
struct SidebarChatPullMark: View {
    let pulls: [ChatPull]
    let open: (ChatPull) -> Void
    @State private var showing = false
    @State private var held = false
    @State private var overMark = false
    @State private var overCard = false

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

struct SidebarPullMarkSeat: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
#endif

#if os(iOS)
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
