// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// The picture at the top of each step of the setup wizard.
///
/// One per step, because a wizard that draws the same glyph six times is a
/// form with a decoration on it. Each of these is the step's own verb: looking
/// for a machine, unlocking one, recognising one, reading it, filling it, and
/// the light coming on.
///
/// Same hand as `ClientEmptyArt`: SwiftUI shapes on the shared `Ink` palette,
/// one small loop each, and Reduce Motion lands on the resting frame and stays
/// there. Nothing here is a bitmap and nothing needs a symbol that Apple might
/// rename.
enum SetupArtKind: Hashable {
    /// Which server. A rack, and the beam that is looking for it.
    case find
    /// How to sign in. A key going into a lock that opens.
    case unlock
    /// The host key. A fingerprint that draws itself and is recognised.
    case identify
    /// What is on the machine. A list that ticks itself off.
    case inspect
    /// The install. A package landing in the rack, and the bar filling.
    case install
}

struct ClientSetupArt: View {
    let kind: SetupArtKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One canvas for every step, so the header does not jump by a pixel as
    /// somebody walks through.
    static let size = CGSize(width: 132, height: 72)

    var body: some View {
        Group {
            switch kind {
            case .find: FindScene(reduceMotion: reduceMotion)
            case .unlock: UnlockScene(reduceMotion: reduceMotion)
            case .identify: IdentifyScene(reduceMotion: reduceMotion)
            case .inspect: InspectScene(reduceMotion: reduceMotion)
            case .install: InstallScene(reduceMotion: reduceMotion)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - 1. Which server

/// A rack with a beam passing over it, and the unit it settles on lighting up.
///
/// The sweep is one pass that repeats, not a spinner: the step is a choice
/// somebody is about to make, and a spinner would say the app is busy.
private struct FindScene: View {
    var reduceMotion: Bool
    @State private var sweep: CGFloat = 0

    private let units = 3

    var body: some View {
        ZStack {
            rack
            if !reduceMotion {
                beam
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                sweep = 1
            }
        }
    }

    private var rack: some View {
        VStack(spacing: 4) {
            ForEach(0..<units, id: \.self) { unit in
                ArtFrame(radius: 4, color: lit(unit) ? Ink.lead : Ink.quiet)
                    .frame(width: 74, height: 16)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(lit(unit) ? Ink.lead : Ink.quiet)
                            .frame(width: 5, height: 5)
                            .padding(.leading, 7)
                    }
                    .overlay(alignment: .trailing) {
                        Ghost(width: 26, color: lit(unit) ? Ink.lead.opacity(0.7) : Ink.second)
                            .padding(.trailing, 8)
                    }
            }
        }
    }

    /// Which unit the beam is over. Reduce Motion lights the middle one, so the
    /// resting picture is still a machine that has been found.
    private func lit(_ unit: Int) -> Bool {
        guard !reduceMotion else { return unit == 1 }
        return Int(round(sweep * CGFloat(units - 1))) == unit
    }

    private var beam: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Ink.lead.opacity(0), Ink.lead.opacity(0.5), Ink.lead.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 92, height: 12)
            .offset(y: -20 + sweep * 40)
            .blendMode(.plusLighter)
    }
}

// MARK: - 2. How to sign in

/// A key sliding into a shackle that opens. The one thing this step does.
///
/// The shackle hinges on one side and stays on the body, because a padlock
/// whose top floats free is not a padlock that has opened, it is a padlock in
/// two pieces.
private struct UnlockScene: View {
    var reduceMotion: Bool
    @State private var turned = false

    private var open: Bool { reduceMotion || turned }

    var body: some View {
        HStack(spacing: 12) {
            key
            lock
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                turned = true
            }
        }
    }

    /// A bow, a shaft and two teeth. A key at this size is three strokes, and
    /// anything more reads as noise.
    private var key: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Ink.lead, style: Ink.style)
                .frame(width: 14, height: 14)
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(Ink.lead)
                    .frame(width: 22, height: Ink.width)
                HStack(alignment: .top, spacing: 4) {
                    Capsule().fill(Ink.lead).frame(width: Ink.width, height: 7)
                    Capsule().fill(Ink.lead).frame(width: Ink.width, height: 5)
                }
                .offset(y: 4)
            }
        }
        // Into the lock and back out, which is the movement the animation is
        // actually about.
        .offset(x: open ? 5 : -3)
        // The bow is the widest part, so centring on the shaft leaves the key
        // sitting low against the lock body.
        .padding(.bottom, 6)
    }

    private var lock: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(open ? Ink.lead : Ink.quiet, style: Ink.style)
                .frame(width: 30, height: 24)
                .overlay {
                    Circle()
                        .fill(open ? Ink.lead : Ink.quiet)
                        .frame(width: 5, height: 5)
                }
            Shackle()
                .stroke(open ? Ink.lead : Ink.quiet, style: Ink.style)
                .frame(width: 18, height: 15)
                // Hinged on the left post, so it swings rather than lifting
                // off, and the right post clears the body by two points.
                .rotationEffect(.degrees(open ? -22 : 0), anchor: .bottomLeading)
                .offset(y: -22)
        }
        .frame(height: 42, alignment: .bottom)
    }
}

/// The half-loop of a padlock: up one side, over, and down the other.
private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

// MARK: - 3. The host key

/// A fingerprint that draws itself, then is recognised.
///
/// Arcs traced with `trim` rather than a symbol, so the drawing is the
/// animation. The gaps are staggered and the centres drift, because four
/// concentric circles with the same gap read as a rainbow rather than a print.
///
/// The badge arrives only once the whorl is complete: this is the step where a
/// mistake is permanent, and the picture must not say "known" before the
/// question has been asked.
private struct IdentifyScene: View {
    var reduceMotion: Bool
    @State private var drawn: CGFloat = 0

    private let arcs = 5

    var body: some View {
        ZStack {
            ForEach(0..<arcs, id: \.self) { arc in
                let size = CGFloat(14 + arc * 11)
                Circle()
                    .trim(from: gap(arc), to: gap(arc) + span(arc) * progress(arc))
                    .stroke(Ink.lead.opacity(1 - Double(arc) * 0.13), style: Ink.style)
                    .frame(width: size, height: size)
                    // A print is a set of ridges around one core, not a set of
                    // rings around one centre.
                    .offset(y: CGFloat(arc) * -1.6)
            }
            badge
                .offset(x: 26, y: 22)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                drawn = 1
            }
        }
    }

    private var badge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.background, Ink.lead)
            .opacity(complete ? 1 : 0)
            .scaleEffect(complete ? 1 : 0.5)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: complete)
    }

    private var complete: Bool { reduceMotion || drawn > 0.88 }

    /// Where each ridge starts, staggered so the open side is ragged.
    private func gap(_ arc: Int) -> CGFloat {
        0.30 + CGFloat(arc) * 0.035
    }

    /// Inner ridges are nearly closed, outer ones are shorter, which is what
    /// gives the shape a core.
    private func span(_ arc: Int) -> CGFloat {
        0.74 - CGFloat(arc) * 0.055
    }

    /// Outer ridges finish after inner ones, so the whorl grows outward
    /// instead of five rings appearing at once.
    private func progress(_ arc: Int) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let start = CGFloat(arc) * 0.11
        return min(1, max(0, (drawn - start) / (1 - start)))
    }
}

// MARK: - 4. What is on it

/// A short list that ticks itself off, one line at a time.
private struct InspectScene: View {
    var reduceMotion: Bool
    @State private var checked: CGFloat = 0

    private let lines = 4

    var body: some View {
        ArtFrame(radius: 8)
            .frame(width: 88, height: 62)
            .overlay {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<lines, id: \.self) { line in
                        HStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        ticked(line) ? Ink.lead : Ink.quiet,
                                        lineWidth: Ink.width
                                    )
                                    .frame(width: 9, height: 9)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .black))
                                    .foregroundStyle(Ink.lead)
                                    .opacity(ticked(line) ? 1 : 0)
                            }
                            Ghost(
                                width: [30, 22, 34, 18][line],
                                color: ticked(line) ? Ink.lead.opacity(0.7) : Ink.second
                            )
                        }
                        .animation(.easeOut(duration: 0.25), value: ticked(line))
                    }
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    checked = 1
                }
            }
    }

    private func ticked(_ line: Int) -> Bool {
        guard !reduceMotion else { return true }
        // The last quarter of the loop has everything ticked, so the list is
        // seen finished rather than resetting the moment it completes.
        return checked > CGFloat(line) * 0.19
    }
}

// MARK: - 5. Install

/// A package dropping into the rack, and the bar underneath filling behind it.
///
/// The same rack as step one, at the same width, so the machine somebody found
/// is visibly the machine being filled.
private struct InstallScene: View {
    var reduceMotion: Bool
    @State private var phase: CGFloat = 0

    private let units = 3

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                rack
                // Starts at the top of the canvas and falls into the first
                // slot, so nothing is drawn outside the frame the header
                // reserves for it.
                package
                    .offset(y: reduceMotion ? 6 : phase * 15)
                    // It goes in rather than landing on top: the fade is the
                    // last quarter of the fall.
                    .opacity(reduceMotion ? 0.9 : 1 - max(0, phase - 0.7) * 3.2)
            }
            bar
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeIn(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var rack: some View {
        VStack(spacing: 4) {
            ForEach(0..<units, id: \.self) { unit in
                ArtFrame(radius: 4, color: filled(unit) ? Ink.lead : Ink.quiet)
                    .frame(width: 74, height: 13)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(filled(unit) ? Ink.lead : Ink.quiet)
                            .frame(width: 4, height: 4)
                            .padding(.leading, 7)
                    }
            }
        }
        .padding(.top, 15)
    }

    /// Units light from the top down as the bar fills, so the rack itself is
    /// the progress rather than only the bar under it.
    private func filled(_ unit: Int) -> Bool {
        guard !reduceMotion else { return unit == 0 }
        return phase > CGFloat(unit) * 0.3 + 0.08
    }

    /// A box with a seam down it, which reads as something being delivered
    /// rather than as another rectangle.
    private var package: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Ink.lead, style: Ink.style)
            .frame(width: 20, height: 16)
            .overlay {
                Rectangle().fill(Ink.lead).frame(width: Ink.width, height: 16)
            }
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var bar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Ink.quiet).frame(width: 74, height: 4)
            Capsule()
                .fill(Ink.lead)
                .frame(width: 74 * (reduceMotion ? 0.72 : phase), height: 4)
        }
    }
}

#endif
