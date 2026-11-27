// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

enum EmptyArtKind {
    case sessions
    case tasks
    case notes
    case workflows
    case automations
    case changes
    case history
    case notGit
    case files
    case projects
    case waiting
    case remoteReach
    case vault
    case screen
    case workspaceAccess
    case chat(seed: UInt64)
    case noMachine
    case provisioning
    case serverReady
    case connect
    case macDoor
    case cloudDoor
    case rentServer
    case byHand
    case firstBars
    case getCounting
    case remoteGate
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

    static let size = CGSize(width: 128, height: 84)

    var body: some View {
        Group {
            switch kind {
            case .noMachine: ServerScene(reduceMotion: reduceMotion, state: .waiting)
            case .provisioning: ServerScene(reduceMotion: reduceMotion, state: .working)
            case .serverReady: ServerScene(reduceMotion: reduceMotion, state: .ready)
            case .connect:
                Image("SetupConnection").resizable().scaledToFit()
            case .macDoor: MacDoorScene(reduceMotion: reduceMotion)
            case .cloudDoor: CloudDoorScene(reduceMotion: reduceMotion)
            case .rentServer: RentScene(reduceMotion: reduceMotion)
            case .byHand: ByHandScene(reduceMotion: reduceMotion)
            case .firstBars: FirstBarsScene(reduceMotion: reduceMotion)
            case .getCounting: GetCountingScene(reduceMotion: reduceMotion)
            case .remoteGate: RemoteGateScene(reduceMotion: reduceMotion)
            case .sessions: SessionsScene(reduceMotion: reduceMotion)
            case .tasks: TasksScene(reduceMotion: reduceMotion)
            case .notes: NotesScene(reduceMotion: reduceMotion)
            case .workflows: WorkflowsScene(reduceMotion: reduceMotion)
            case .automations: AutomationsScene(reduceMotion: reduceMotion)
            case .changes: ChangesScene(reduceMotion: reduceMotion)
            case .history: HistoryScene(reduceMotion: reduceMotion)
            case .notGit: NotGitScene(reduceMotion: reduceMotion)
            case .files: FilesScene(reduceMotion: reduceMotion)
            case .projects: FirstProjectArt()
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


enum Ink {
    static let width: CGFloat = 1.7
    static var style: StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    static var quiet: Color { Theme.border }
    static var lead: Color { Theme.accent }
    static var second: Color { Theme.secondary }
}

struct ArtFrame: View {
    var radius: CGFloat = 8
    var color: Color = Ink.quiet

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, style: Ink.style)
    }
}

struct Ghost: View {
    var width: CGFloat
    var color: Color = Ink.quiet

    var body: some View {
        Capsule().fill(color).frame(width: width, height: Ink.width)
    }
}


private struct ServerScene: View {
    enum State { case waiting, working, ready }

    var reduceMotion: Bool
    var state: State

    @SwiftUI.State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 16) {
            phone
            link
            rack
        }
        .clientArtLoop(enabled: !reduceMotion && state != .waiting, duration: 1.3, animation: .easeInOut(duration: 1.3)) { active in
            phase = active ? 1 : 0
        }
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Ink.quiet, style: Ink.style)
            .frame(width: 22, height: 38)
            .overlay { Ghost(width: 10, color: Ink.second) }
    }

    private var link: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(dotColor(index))
                    .frame(width: 4, height: 4)
                    .opacity(dotOpacity(index))
            }
        }
    }

    private func dotColor(_ index: Int) -> Color {
        switch state {
        case .waiting: Ink.quiet
        case .working: Ink.lead
        case .ready: Ink.lead
        }
    }

    private func dotOpacity(_ index: Int) -> CGFloat {
        switch state {
        case .waiting: 0.5
        case .ready: 1
        case .working:
            reduceMotion ? 0.7 : 0.35 + 0.65 * max(0, 1 - abs(phase * 3 - CGFloat(index)))
        }
    }

    private var rack: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { unit in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Ink.quiet, style: Ink.style)
                    .frame(width: 44, height: 13)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(unit == 0 ? light : Ink.quiet)
                            .frame(width: 4, height: 4)
                            .padding(.leading, 5)
                    }
                    .overlay(alignment: .trailing) {
                        Ghost(width: 16, color: Ink.second)
                            .padding(.trailing, 6)
                    }
            }
        }
    }

    private var light: Color {
        switch state {
        case .waiting: Ink.quiet
        case .working: Ink.lead.opacity(reduceMotion ? 0.8 : 0.4 + 0.6 * phase)
        case .ready: Ink.lead
        }
    }
}


private struct Sparkle: View {
    var size: CGFloat = 10

    var body: some View {
        Path { path in
            let half = size / 2
            let inner = size * 0.16
            path.move(to: CGPoint(x: half, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: size, y: half),
                control: CGPoint(x: half + inner, y: half - inner)
            )
            path.addQuadCurve(
                to: CGPoint(x: half, y: size),
                control: CGPoint(x: half + inner, y: half + inner)
            )
            path.addQuadCurve(
                to: CGPoint(x: 0, y: half),
                control: CGPoint(x: half - inner, y: half + inner)
            )
            path.addQuadCurve(
                to: CGPoint(x: half, y: 0),
                control: CGPoint(x: half - inner, y: half - inner)
            )
        }
        .fill(Ink.lead)
        .frame(width: size, height: size)
    }
}

private struct MacDoorScene: View {
    var reduceMotion: Bool
    @State private var lowered = false

    var body: some View {
        ZStack {
            VStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(Theme.fixed(13, weight: .semibold))
                    .foregroundStyle(Ink.lead)
                    .offset(y: reduceMotion || !lowered ? 0 : 4)
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Ink.quiet, style: Ink.style)
                        .frame(width: 56, height: 36)
                        .overlay { Ghost(width: 22, color: Ink.second) }
                    Capsule()
                        .fill(Ink.quiet)
                        .frame(width: 72, height: 2)
                }
            }
            Sparkle(size: 11)
                .offset(x: -34, y: -20)
            Sparkle(size: 7)
                .offset(x: 34, y: 16)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.1, animation: .easeInOut(duration: 1.1)) { active in
            lowered = active ? true : false
        }
    }
}

private struct CloudDoorScene: View {
    var reduceMotion: Bool
    @State private var fall: CGFloat = 0

    private let drops = 3
    private let height: CGFloat = 18

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                cloud
                ZStack(alignment: .top) {
                    Color.clear.frame(width: 60, height: height)
                    ForEach(0..<drops, id: \.self) { drop in
                        Circle()
                            .fill(Ink.lead.opacity(opacity(drop)))
                            .frame(width: 4, height: 4)
                            .offset(y: y(drop))
                    }
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Ink.lead.opacity(0.6), style: Ink.style)
                    .frame(width: 56, height: 16)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(Ink.lead)
                            .frame(width: 4, height: 4)
                            .padding(.leading, 6)
                    }
                    .overlay(alignment: .trailing) {
                        Ghost(width: 20, color: Ink.second)
                            .padding(.trailing, 7)
                    }
            }
            Sparkle(size: 9)
                .offset(x: -38, y: -20)
            Sparkle(size: 7)
                .offset(x: 34, y: 22)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.5, animation: .linear(duration: 1.5), autoreverses: false) { active in
            fall = active ? 1 : 0
        }
    }

    private var cloud: some View {
        Capsule()
            .fill(Theme.background)
            .frame(width: 62, height: 22)
            .overlay {
                Capsule().strokeBorder(Ink.quiet, style: Ink.style)
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Theme.background)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle().strokeBorder(Ink.quiet, style: Ink.style)
                    }
                    .offset(x: 9, y: -9)
            }
    }

    private func progress(_ drop: Int) -> CGFloat {
        guard !reduceMotion else { return 0.5 }
        return (fall + CGFloat(drop) / CGFloat(drops)).truncatingRemainder(dividingBy: 1)
    }

    private func y(_ drop: Int) -> CGFloat {
        progress(drop) * height
    }

    private func opacity(_ drop: Int) -> CGFloat {
        let progress = progress(drop)
        return progress > 0.8 ? max(0, 1 - (progress - 0.8) / 0.2) : 1
    }
}

private struct RentScene: View {
    var reduceMotion: Bool
    @State private var swayed = false

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Ink.lead.opacity(0.7), style: Ink.style)
                        .frame(width: 34, height: 24)
                    Circle()
                        .fill(Ink.lead)
                        .frame(width: 4, height: 4)
                        .padding(.leading, 6)
                        .padding(.top, 10)
                    Ghost(width: 13, color: Ink.second)
                        .padding(.leading, 13)
                        .padding(.top, 11)
                }
                .rotationEffect(.degrees(reduceMotion || !swayed ? -12 : -4))
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Ink.quiet, style: Ink.style)
                            .frame(width: 44, height: 13)
                    }
                }
            }
            Sparkle(size: 9)
                .offset(x: -40, y: -14)
            Sparkle(size: 6)
                .offset(x: 36, y: 16)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.6, animation: .easeInOut(duration: 1.6)) { active in
            swayed = active ? true : false
        }
    }
}

private struct ByHandScene: View {
    var reduceMotion: Bool
    @State private var on = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .topLeading) {
                ArtFrame()
                VStack(alignment: .leading, spacing: 8) {
                    Ghost(width: 40, color: Ink.lead.opacity(0.7))
                    HStack(spacing: 5) {
                        Ghost(width: 30)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Ink.lead)
                            .frame(width: 6, height: 11)
                            .opacity(reduceMotion || on ? 1 : 0.15)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
            }
            .frame(width: 84, height: 56)
            ZStack {
                Circle().fill(Theme.background)
                Circle().strokeBorder(Ink.lead, style: Ink.style)
                Image(systemName: "arrow.down.to.line")
                    .font(Theme.fixed(8, weight: .semibold))
                    .foregroundStyle(Ink.lead)
            }
            .frame(width: 20, height: 20)
            .offset(x: 6, y: 6)
            Sparkle(size: 8)
                .offset(x: -50, y: -24)
            Sparkle(size: 6)
                .offset(x: 52, y: 28)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 0.6, animation: .easeInOut(duration: 0.6)) { active in
            on = active ? true : false
        }
    }
}

private struct FirstBarsScene: View {
    var reduceMotion: Bool
    @State private var filling = false

    var body: some View {
        ZStack {
            VStack(spacing: 5) {
                HStack(alignment: .bottom, spacing: 9) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Ink.lead.opacity(0.85))
                        .frame(width: 16, height: 20)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Ink.lead.opacity(0.85))
                        .frame(width: 16, height: 34)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            Ink.lead,
                            style: StrokeStyle(lineWidth: Ink.width, lineCap: .round, dash: [4, 4])
                        )
                        .frame(width: 16, height: 48)
                        .opacity(reduceMotion ? 0.6 : (filling ? 0.9 : 0.35))
                }
                Capsule()
                    .fill(Ink.quiet)
                    .frame(width: 66, height: 2)
            }
            Sparkle(size: 9)
                .offset(x: -36, y: -22)
            Sparkle(size: 6)
                .offset(x: 36, y: 20)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.4, animation: .easeInOut(duration: 1.4)) { active in
            filling = active ? true : false
        }
    }
}

private struct GetCountingScene: View {
    var reduceMotion: Bool
    @State private var waiting = false

    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Ink.lead.opacity(0.6), style: Ink.style)
                        .frame(width: 24, height: 40)
                        .overlay { Ghost(width: 11, color: Ink.second) }
                    ZStack {
                        Circle().fill(Ink.lead).frame(width: 15, height: 15)
                        Image(systemName: "checkmark")
                            .font(Theme.fixed(8, weight: .bold))
                            .foregroundStyle(Theme.background)
                    }
                    .offset(x: 6, y: 6)
                }
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Ink.quiet, style: Ink.style)
                            .frame(width: 40, height: 12)
                            .overlay(alignment: .leading) {
                                Circle()
                                    .fill(Ink.lead.opacity(reduceMotion ? 0.5 : (waiting ? 0.9 : 0.25)))
                                    .frame(width: 4, height: 4)
                                    .padding(.leading, 5)
                            }
                    }
                }
            }
            Sparkle(size: 9)
                .offset(x: -40, y: -20)
            Sparkle(size: 6)
                .offset(x: 40, y: 18)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.5, animation: .easeInOut(duration: 1.5)) { active in
            waiting = active ? true : false
        }
    }
}

private struct RemoteGateScene: View {
    var reduceMotion: Bool
    @State private var closed = false

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Ink.quiet, style: Ink.style)
                    .frame(width: 20, height: 34)
                    .overlay { Ghost(width: 9, color: Ink.second) }
                ZStack {
                    Circle().fill(Ink.lead).frame(width: 20, height: 20)
                    Image(systemName: "lock.fill")
                        .font(Theme.fixed(9, weight: .medium))
                        .foregroundStyle(Theme.background)
                }
                .scaleEffect(reduceMotion || !closed ? 1 : 1.12)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Ink.lead.opacity(0.7), style: Ink.style)
                        .frame(width: 44, height: 30)
                    Circle()
                        .fill(Theme.background)
                        .frame(width: 20, height: 12)
                        .overlay {
                            Capsule().strokeBorder(Ink.lead.opacity(0.7), style: Ink.style)
                        }
                        .offset(x: 5, y: -5)
                }
            }
            Sparkle(size: 9)
                .offset(x: -44, y: -22)
            Sparkle(size: 6)
                .offset(x: 44, y: 20)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.6, animation: .easeInOut(duration: 1.6)) { active in
            closed = active ? true : false
        }
    }
}


private struct SessionsScene: View {
    var reduceMotion: Bool
    @State private var on = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtFrame()
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
        .clientArtLoop(enabled: !reduceMotion, duration: 0.6, animation: .easeInOut(duration: 0.6)) { active in
            on = active ? true : false
        }
    }
}


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
        .clientArtLoop(enabled: !reduceMotion, duration: 1.8, animation: .easeInOut(duration: 1.8)) { active in
            nudged = active ? true : false
        }
    }

    private func lane(filled: Bool) -> some View {
        VStack(spacing: 6) {
            Ghost(width: 18, color: filled ? Ink.lead : Ink.quiet)
            ZStack {
                ArtFrame(radius: 6, color: filled ? Ink.lead.opacity(0.55) : Ink.quiet)
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
        .clientArtLoop(enabled: !reduceMotion, duration: 1.6, animation: .easeInOut(duration: 1.6)) { active in
            written = active ? true : false
        }
    }

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
        .clientArtLoop(enabled: !reduceMotion, duration: 1.4, animation: .linear(duration: 1.4), autoreverses: false) { active in
            travelled = active ? true : false
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

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Ink.quiet,
                    style: StrokeStyle(lineWidth: Ink.width, lineCap: .round, dash: [4, 5])
                )
                .frame(width: 86, height: 20)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 4, animation: .linear(duration: 4), autoreverses: false) { active in
            swept = active ? true : false
        }
    }
}


private struct ChangesScene: View {
    var reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtFrame()
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


private struct HistoryScene: View {
    var reduceMotion: Bool
    @State private var lit = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Capsule()
                    .fill(Ink.quiet)
                    .frame(width: Ink.width, height: 52)
                VStack(spacing: 14) {
                    Circle()
                        .strokeBorder(
                            Ink.lead,
                            style: StrokeStyle(lineWidth: Ink.width, lineCap: .round, dash: [3, 3])
                        )
                        .background(
                            Circle().fill(Theme.accentSoft.opacity(lit || reduceMotion ? 1 : 0.2))
                        )
                        .frame(width: 14, height: 14)
                        .scaleEffect(reduceMotion || lit ? 1 : 0.82)
                    Circle()
                        .strokeBorder(Ink.quiet, style: Ink.style)
                        .frame(width: 12, height: 12)
                    Circle()
                        .strokeBorder(Ink.quiet, style: Ink.style)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Ghost(width: 48, color: Ink.lead)
                    Ghost(width: 28)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Ghost(width: 56)
                    Ghost(width: 36)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Ghost(width: 40)
                    Ghost(width: 24)
                }
            }
            .padding(.top, 1)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.35, animation: .easeInOut(duration: 1.35)) { active in
            lit = active ? true : false
        }
    }
}


private struct NotGitScene: View {
    var reduceMotion: Bool
    @State private var travelled = false

    var body: some View {
        HStack(spacing: 16) {
            folder
                .fill(Theme.accentSoft)
                .overlay { folder.stroke(Ink.lead, style: Ink.style) }
                .frame(width: 56, height: 34)

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 2, y: 25))
                    path.addLine(to: CGPoint(x: 20, y: 25))
                    path.addLine(to: CGPoint(x: 36, y: 10))
                    path.move(to: CGPoint(x: 20, y: 25))
                    path.addLine(to: CGPoint(x: 36, y: 40))
                }
                .stroke(
                    Ink.lead.opacity(0.85),
                    style: StrokeStyle(
                        lineWidth: Ink.width,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [4, 4],
                        dashPhase: reduceMotion || !travelled ? 0 : -16
                    )
                )
                Circle()
                    .strokeBorder(Ink.lead, style: Ink.style)
                    .background(Circle().fill(Theme.accentSoft))
                    .frame(width: 11, height: 11)
                    .offset(x: -18, y: 0)
                Circle()
                    .strokeBorder(Ink.quiet, style: Ink.style)
                    .frame(width: 9, height: 9)
                    .offset(x: 16, y: -15)
                Circle()
                    .strokeBorder(Ink.quiet, style: Ink.style)
                    .frame(width: 9, height: 9)
                    .offset(x: 16, y: 15)
            }
            .frame(width: 44, height: 50)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.5, animation: .linear(duration: 1.5), autoreverses: false) { active in
            travelled = active ? true : false
        }
    }

    private var folder: Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 33))
        path.addLine(to: CGPoint(x: 1, y: 6))
        path.addLine(to: CGPoint(x: 16, y: 6))
        path.addLine(to: CGPoint(x: 21, y: 12))
        path.addLine(to: CGPoint(x: 55, y: 12))
        path.addLine(to: CGPoint(x: 55, y: 33))
        path.closeSubpath()
        return path
    }
}


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


private struct WaitingScene: View {
    var reduceMotion: Bool
    @Environment(\.scenePhase) private var scenePhase
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
                        .animation(reduceMotion || scenePhase != .active ? nil
                                   : .easeInOut(duration: 1.5).delay(Double(index) * 0.18), value: out)
                }
            }
            .frame(width: 38, height: 60)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.86, animation: nil) { active in
            out = active
        }
    }
}


private struct RemoteReachScene: View {
    var reduceMotion: Bool
    @State private var sending = false

    var body: some View {
        ZStack {
            phone.offset(x: -42, y: 8)
            mac.offset(x: 28, y: -3)
            signal.offset(x: -2, y: 6)
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.45, animation: .easeInOut(duration: 1.45)) { active in
            sending = active ? true : false
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
        .clientArtLoop(enabled: !reduceMotion, duration: 1.7, animation: .easeInOut(duration: 1.7)) { active in
            together = active ? true : false
        }
    }

    private var togetherOffset: CGFloat {
        reduceMotion || together ? 34 : 42
    }

    private func deviceFrame(width: CGFloat, height: CGFloat) -> some View {
        ArtFrame(radius: 6)
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
            .clientArtLoop(enabled: !reduceMotion, duration: 1.8, animation: .easeInOut(duration: 1.8)) { active in
                scan = active ? true : false
            }
    }
}

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


private struct WorkspaceAccessScene: View {
    let reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        ZStack {
            ArtFrame(radius: 10)
                .frame(width: 74, height: 54)
                .offset(x: -14, y: 6)
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
        }
        .clientArtLoop(enabled: !reduceMotion, duration: 1.9, animation: .easeInOut(duration: 1.9)) { active in
            settled = active
        }
    }
}


private struct ChatEmptyScene: View {
    var seed: UInt64

    var body: some View {
        PersonaPastime(seed: seed, size: 84, doing: .leisure)
    }
}

#endif
