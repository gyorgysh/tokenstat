// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Which picture an empty screen draws.
///
/// One per surface, because "nothing here" is a different sentence in a folder
/// with no sessions and a folder with no jobs. A shared tray glyph made all of
/// them read as the same shrug.
enum EmptyArtKind {
    case sessions
    case tasks
    case notes
    case workflows
    case automations
    case changes
    case files
    /// The host has not answered yet. Deliberately not one of the others: a
    /// question nobody replied to is not an empty answer.
    case waiting
    /// A Mac has not answered a phone or iPad. The scene shows the outgoing
    /// reach and the Remote Reach switch that must be changed on the Mac.
    case remoteReach
    /// Cross-device SSH vault, shown when the plan does not include it.
    case vault
    /// Remote screen, shown when the plan does not include Legend.
    case screen
    /// Another computer has not let this device open its work yet.
    case workspaceAccess
    /// A folder with no chats yet. Carries the face the next conversation in
    /// it will have, so the character on the empty screen is the one that
    /// actually turns up.
    case chat(seed: UInt64)
}

/// The picture over an empty state.
///
/// SwiftUI shapes in the brand colours, drawn at the same stroke weight as the
/// marks in `FeatureMarks`, with one small loop each. Reduce Motion lands on
/// the resting frame and stays there, the rule `ClientOnboardingArt` already
/// follows.
struct ClientEmptyArt: View {
    let kind: EmptyArtKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One canvas for every scene, so a screen does not change height when its
    /// picture changes.
    static let size = CGSize(width: 128, height: 84)

    var body: some View {
        Group {
            switch kind {
            case .sessions: SessionsScene(reduceMotion: reduceMotion)
            case .tasks: TasksScene(reduceMotion: reduceMotion)
            case .notes: NotesScene(reduceMotion: reduceMotion)
            case .workflows: WorkflowsScene(reduceMotion: reduceMotion)
            case .automations: AutomationsScene(reduceMotion: reduceMotion)
            case .changes: ChangesScene(reduceMotion: reduceMotion)
            case .files: FilesScene(reduceMotion: reduceMotion)
            case .waiting: WaitingScene(reduceMotion: reduceMotion)
            case .remoteReach: RemoteReachScene(reduceMotion: reduceMotion)
            case .vault: VaultScene(reduceMotion: reduceMotion)
            case .screen: ScreenScene(reduceMotion: reduceMotion)
            case .workspaceAccess: WorkspaceAccessScene(reduceMotion: reduceMotion)
            case let .chat(seed): ChatEmptyScene(seed: seed)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared parts

/// The stroke every scene draws with. One weight, round joins, so the
/// pictures read as one hand.
private enum Ink {
    static let width: CGFloat = 1.7
    static var style: StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    static var quiet: Color { Theme.border }
    static var lead: Color { Theme.accent }
    static var second: Color { Theme.secondary }
}

/// A card outline, the shape most of these are built from.
private struct Frame: View {
    var radius: CGFloat = 8
    var color: Color = Ink.quiet

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, style: Ink.style)
    }
}

/// A line of text that is not there yet.
private struct Ghost: View {
    var width: CGFloat
    var color: Color = Ink.quiet

    var body: some View {
        Capsule().fill(color).frame(width: width, height: Ink.width)
    }
}

// MARK: - Sessions

/// A terminal waiting for its first command: the frame, a prompt, a caret that
/// blinks the way the real one does.
private struct SessionsScene: View {
    var reduceMotion: Bool
    @State private var on = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Frame()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Circle().fill(Ink.quiet).frame(width: 5, height: 5)
                    Circle().fill(Ink.quiet).frame(width: 5, height: 5)
                    Circle().fill(Ink.lead.opacity(0.6)).frame(width: 5, height: 5)
                }
                HStack(spacing: 6) {
                    Text(">")
                        .font(Theme.monoText(12, weight: .semibold))
                        .foregroundStyle(Ink.lead)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Ink.lead)
                        .frame(width: 7, height: 13)
                        .opacity(reduceMotion || on ? 1 : 0.15)
                }
                Ghost(width: 46)
            }
            .padding(.horizontal, 14)
            .padding(.top, 15)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                on = true
            }
        }
    }
}

// MARK: - Tasks

/// Three lanes with one card in the first: the board before anybody has moved
/// anything. The card leans toward the lane it would go to next.
private struct TasksScene: View {
    var reduceMotion: Bool
    @State private var nudged = false

    var body: some View {
        HStack(spacing: 8) {
            lane(filled: true)
            lane(filled: false)
            lane(filled: false)
        }
        .padding(.horizontal, 12)
        .offset(x: reduceMotion || !nudged ? 0 : 3)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                nudged = true
            }
        }
    }

    private func lane(filled: Bool) -> some View {
        VStack(spacing: 6) {
            Ghost(width: 18, color: filled ? Ink.lead : Ink.quiet)
            ZStack {
                Frame(radius: 6, color: filled ? Ink.lead.opacity(0.55) : Ink.quiet)
                if filled {
                    VStack(alignment: .leading, spacing: 5) {
                        Ghost(width: 18, color: Ink.lead.opacity(0.7))
                        Ghost(width: 11)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 34)
        }
    }
}

// MARK: - Notes

/// A sheet with a folded corner and one line still being written.
private struct NotesScene: View {
    var reduceMotion: Bool
    @State private var written = false

    private let size = CGSize(width: 96, height: 66)
    private let fold: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            sheet
                .stroke(Ink.quiet, style: Ink.style)
            Path { path in
                path.move(to: CGPoint(x: size.width - fold, y: 0))
                path.addLine(to: CGPoint(x: size.width - fold, y: fold))
                path.addLine(to: CGPoint(x: size.width, y: fold))
            }
            .stroke(Ink.second, style: Ink.style)

            VStack(alignment: .leading, spacing: 9) {
                Ghost(width: 34, color: Ink.lead)
                Ghost(width: 52)
                Capsule()
                    .fill(Ink.lead)
                    .frame(width: reduceMotion || written ? 40 : 8, height: Ink.width)
            }
            .padding(.leading, 14)
            .padding(.top, 24)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                written = true
            }
        }
    }

    /// The page, with the corner taken off rather than drawn over.
    private var sheet: Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: size.width - fold, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: fold))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Workflows

/// Three nodes and the run that has not passed through them: the connectors are
/// dashed and the dashes travel, so the graph reads as a route rather than a
/// diagram.
private struct WorkflowsScene: View {
    var reduceMotion: Bool
    @State private var travelled = false

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 22, y: 42))
                path.addLine(to: CGPoint(x: 58, y: 42))
                path.move(to: CGPoint(x: 74, y: 42))
                path.addLine(to: CGPoint(x: 106, y: 22))
                path.move(to: CGPoint(x: 74, y: 42))
                path.addLine(to: CGPoint(x: 106, y: 62))
            }
            .stroke(
                Ink.lead.opacity(0.7),
                style: StrokeStyle(
                    lineWidth: Ink.width,
                    lineCap: .round,
                    dash: [4, 4],
                    dashPhase: reduceMotion || !travelled ? 0 : -16
                )
            )
            node(x: 16, y: 42, lead: true)
            node(x: 66, y: 42, lead: false)
            node(x: 112, y: 22, lead: false)
            node(x: 112, y: 62, lead: false)
        }
        .frame(width: ClientEmptyArt.size.width, height: ClientEmptyArt.size.height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                travelled = true
            }
        }
    }

    private func node(x: CGFloat, y: CGFloat, lead: Bool) -> some View {
        Circle()
            .strokeBorder(lead ? Ink.lead : Ink.quiet, style: Ink.style)
            .background(Circle().fill(lead ? Theme.accentSoft : Color.clear))
            .frame(width: 15, height: 15)
            .position(x: x, y: y)
    }
}

// MARK: - Automations

/// A clock with nothing on it: the face is drawn and the hand sweeps, and the
/// row underneath where a job would sit is still an outline.
private struct AutomationsScene: View {
    var reduceMotion: Bool
    @State private var swept = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(Ink.quiet, style: Ink.style)
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Ink.quiet)
                        .frame(width: Ink.width, height: 5)
                        .offset(y: -19)
                        .rotationEffect(.degrees(Double(index) * 90))
                }
                Capsule()
                    .fill(Ink.lead)
                    .frame(width: Ink.width, height: 15)
                    .offset(y: -7.5)
                    .rotationEffect(.degrees(reduceMotion || !swept ? 45 : 405))
                Circle().fill(Ink.lead).frame(width: 4, height: 4)
            }
            .frame(width: 46, height: 46)

            // The empty slot. Dashed, because it is where something would be.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Ink.quiet,
                    style: StrokeStyle(lineWidth: Ink.width, lineCap: .round, dash: [4, 5])
                )
                .frame(width: 86, height: 20)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                swept = true
            }
        }
    }
}

// MARK: - Changes

/// A clean working tree: the gutter is there, every line is unchanged, and the
/// tick settles over it.
private struct ChangesScene: View {
    var reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Frame()
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 8) {
                        Ghost(width: 5)
                        Ghost(width: 54)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            Image(systemName: "checkmark")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Ink.lead)
                .padding(6)
                .background(Theme.accentSoft, in: Circle())
                .overlay(Circle().strokeBorder(Ink.lead.opacity(0.4), lineWidth: 1))
                .offset(x: 86, y: 44)
                .scaleEffect(reduceMotion || settled ? 1 : 0.7)
                .opacity(reduceMotion || settled ? 1 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) {
                settled = true
            }
        }
    }
}

// MARK: - Files

/// A folder with one sheet lifting out of it.
private struct FilesScene: View {
    var reduceMotion: Bool
    @State private var lifted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Ink.quiet, style: Ink.style)
                }
                .frame(width: 38, height: 40)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Ghost(width: 20, color: Ink.second)
                        Ghost(width: 14)
                    }
                    .padding(.top, 11)
                }
                .offset(y: reduceMotion || lifted ? -30 : -20)

            folder
                .fill(Theme.accentSoft)
                .overlay { folder.stroke(Ink.lead, style: Ink.style) }
                .frame(width: 72, height: 42)
        }
        .frame(width: ClientEmptyArt.size.width, height: 78, alignment: .bottom)
    }

    /// A tab along the top edge, then the body. One path, so the fill and the
    /// stroke cannot disagree about where the folder is.
    private var folder: Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 41))
        path.addLine(to: CGPoint(x: 1, y: 4))
        path.addLine(to: CGPoint(x: 24, y: 4))
        path.addLine(to: CGPoint(x: 30, y: 13))
        path.addLine(to: CGPoint(x: 71, y: 13))
        path.addLine(to: CGPoint(x: 71, y: 41))
        path.closeSubpath()
        return path
    }
}

// MARK: - Waiting

/// The question went out and nothing has come back: arcs leaving a machine, and
/// no answer drawn, because there is not one.
private struct WaitingScene: View {
    var reduceMotion: Bool
    @State private var out = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Ink.quiet, style: Ink.style)
                .frame(width: 44, height: 34)
                .overlay { Ghost(width: 22) }

            ZStack(alignment: .leading) {
                ForEach(0..<3, id: \.self) { index in
                    Arc()
                        .stroke(Ink.lead, style: Ink.style)
                        .frame(width: CGFloat(12 + index * 11), height: CGFloat(24 + index * 17))
                        .opacity(reduceMotion ? 0.75 - Double(index) * 0.22 : (out ? 0.12 : 0.9))
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.5)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.18),
                            value: out
                        )
                }
            }
            .frame(width: 38, height: 60)
        }
        .onAppear { out = true }
    }
}

// MARK: - Remote Reach

/// A phone calling a Mac whose Remote Reach switch is still off. The pulse
/// ends at the switch, making this an actionable setup state rather than a
/// vague network failure. Reduce Motion gets its final, still frame.
private struct RemoteReachScene: View {
    var reduceMotion: Bool
    @State private var sending = false

    var body: some View {
        ZStack {
            phone.offset(x: -42, y: 8)
            mac.offset(x: 28, y: -3)
            signal.offset(x: -2, y: 6)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                sending = true
            }
        }
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Ink.quiet, style: Ink.style)
            .frame(width: 26, height: 45)
            .overlay {
                VStack(spacing: 5) {
                    Ghost(width: 12, color: Ink.second)
                    Circle().fill(Ink.lead).frame(width: 5, height: 5)
                }
            }
    }

    private var mac: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Ink.quiet, style: Ink.style)
                .frame(width: 50, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    Capsule()
                        .fill(sending && !reduceMotion ? Ink.lead : Ink.quiet)
                        .frame(width: 17, height: 10)
                        .overlay(alignment: sending && !reduceMotion ? .trailing : .leading) {
                            Circle().fill(Color.white).padding(2)
                        }
                        .padding(5)
                }
            Capsule().fill(Ink.quiet).frame(width: 34, height: Ink.width)
        }
    }

    private var signal: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Ink.lead)
                    .frame(width: 4, height: 4)
                    .opacity(reduceMotion ? 0.45 : (sending
                        ? (index == 2 ? 0.18 : 0.85)
                        : (index == 0 ? 0.18 : 0.85)))
            }
        }
    }
}

// MARK: - Vault

/// Two devices drawing together around a lock: the vault before this plan
/// includes it.
private struct VaultScene: View {
    var reduceMotion: Bool
    @State private var together = false

    var body: some View {
        ZStack {
            deviceFrame(width: 26, height: 44)
                .offset(x: -togetherOffset, y: 6)
            deviceFrame(width: 46, height: 28)
                .offset(x: togetherOffset, y: 10)
            lockMark
                .offset(y: reduceMotion || together ? 0 : 4)
                .opacity(reduceMotion || together ? 1 : 0.65)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                together = true
            }
        }
    }

    private var togetherOffset: CGFloat {
        reduceMotion || together ? 34 : 42
    }

    private func deviceFrame(width: CGFloat, height: CGFloat) -> some View {
        Frame(radius: 6)
            .frame(width: width, height: height)
            .overlay {
                VStack(spacing: 5) {
                    Ghost(width: width * 0.5, color: Ink.second)
                    Ghost(width: width * 0.32)
                }
            }
    }

    private var lockMark: some View {
        VStack(spacing: 0) {
            Path { path in
                path.addArc(
                    center: CGPoint(x: 9, y: 11),
                    radius: 6,
                    startAngle: .degrees(200),
                    endAngle: .degrees(-20),
                    clockwise: false
                )
            }
            .stroke(Ink.lead, style: Ink.style)
            .frame(width: 18, height: 12)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.accentSoft)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Ink.lead, style: Ink.style)
                }
                .frame(width: 20, height: 15)
        }
    }
}

// MARK: - Screen

/// A display with a scan line, the picture that is missing until Legend.
private struct ScreenScene: View {
    var reduceMotion: Bool
    @State private var scan = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.panel)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Ink.lead, style: Ink.style)
            }
            .overlay {
                VStack(spacing: 6) {
                    Ghost(width: 54, color: Ink.second)
                    Ghost(width: 38)
                    Ghost(width: 46, color: Ink.second)
                }
                .padding(.horizontal, 14)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Ink.lead.opacity(0.45))
                    .frame(height: 1.5)
                    .offset(y: reduceMotion ? 28 : (scan ? 52 : 10))
            }
            .frame(width: 88, height: 58)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    scan = true
                }
            }
    }
}

/// One arc of a signal leaving something, opening to the right.
private struct Arc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.minX, y: rect.midY),
            radius: rect.width,
            startAngle: .degrees(-38),
            endAngle: .degrees(38),
            clockwise: false
        )
        return path
    }
}


/// A folder waiting on a key.
///
/// The one empty state in the client that is about permission rather than
/// about emptiness, so the picture is a closed thing and something that opens
/// it, drifting in rather than turning: nothing is locked against this person,
/// it simply has not been handed over yet.
private struct WorkspaceAccessScene: View {
    let reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        ZStack {
            Frame(radius: 10)
                .frame(width: 74, height: 54)
                .offset(x: -14, y: 6)
            // The folder's tab, so the shape reads as a folder and not a card.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Ink.quiet, style: Ink.style)
                .frame(width: 26, height: 10)
                .offset(x: -36, y: -25)
            Image(systemName: "key.fill")
                .font(Theme.font(17, weight: .medium))
                .foregroundStyle(Ink.lead)
                .rotationEffect(.degrees(settled ? -18 : -34))
                .offset(x: settled ? 24 : 38, y: settled ? 10 : -2)
                .opacity(settled ? 1 : 0.5)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.9).repeatForever(autoreverses: true),
                    value: settled
                )
        }
        .onAppear {
            guard !reduceMotion else { return }
            settled = true
        }
    }
}

// MARK: - Chat

/// The Mac chat empty picture, scaled to the client art canvas.
///
/// One character, sized for the 128x84 frame every other empty screen uses.
/// The bubble with three pulsing dots that used to be here was a picture of
/// waiting, and the four harness marks around it named agents nobody has to
/// choose between on this screen.
private struct ChatEmptyScene: View {
    var seed: UInt64

    var body: some View {
        PersonaPastime(seed: seed, size: 84, doing: .leisure)
    }
}

#endif
