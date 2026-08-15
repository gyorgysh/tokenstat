// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Which picture an onboarding page draws. The titles live next door, so a
/// page can change its words without this file knowing the pitch.
enum OnboardingArtKind {
    case intro
    case heatmap
    case devices
    case spend
    case remaining
    case workspaces
    case sessions
    case onTheGo
    case privacy
    case control
}

/// The moving picture on an onboarding page.
///
/// SwiftUI shapes, the brand colours, and the mark the rest of the app already
/// draws. Reduce Motion lands on the last frame and stays there.
struct ClientOnboardingArt: View {
    let kind: OnboardingArtKind
    var reduceMotion: Bool

    var body: some View {
        ZStack {
            Group {
                switch kind {
                case .intro: IntroArt(reduceMotion: reduceMotion)
                case .heatmap: HeatmapArt(reduceMotion: reduceMotion)
                case .devices: DevicesArt(reduceMotion: reduceMotion)
                case .spend: SpendArt(reduceMotion: reduceMotion)
                case .remaining: RemainingArt(reduceMotion: reduceMotion)
                case .workspaces: WorkspacesArt(reduceMotion: reduceMotion)
                case .sessions: SessionsArt(reduceMotion: reduceMotion)
                case .onTheGo: OnTheGoArt(reduceMotion: reduceMotion)
                case .privacy: PrivacyArt(reduceMotion: reduceMotion)
                case .control: ControlArt(reduceMotion: reduceMotion)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .accessibilityHidden(true)
    }
}

// MARK: - What tokenstat is

private struct IntroArt: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            // One rise, not the launch splash's pulse: the page is a pitch and
            // the mark lands and stays, so the bars hold their full height
            // instead of drumming through the whole paragraph below.
            LogoMark(size: 72, animated: !reduceMotion, loops: false)
            Wordmark(size: 26, fills: false, showsMark: false)
        }
    }
}

// MARK: - Your AI Heatmap

private struct HeatmapArt: View {
    var reduceMotion: Bool
    @State private var phase: CGFloat = 0

    private let columns = 12
    private let rows = 7
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        let step = cell + gap
        HStack(alignment: .center, spacing: gap) {
            ForEach(0..<columns, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                            .fill(Theme.heat[level(col: col, row: row)])
                            .frame(width: cell, height: cell)
                    }
                }
                .offset(y: reduceMotion ? 0 : wave(col: col) * 3)
            }
        }
        .frame(width: CGFloat(columns) * step - gap, height: CGFloat(rows) * step - gap)
        .onAppear { run() }
    }

    private func level(col: Int, row: Int) -> Int {
        let wave = sin(Double(col) * 0.55 + Double(row) * 0.28 + Double(phase) * .pi * 2)
        let scaled = (wave + 1) / 2
        return min(4, max(0, Int((scaled * 4.4).rounded(.down))))
    }

    private func wave(col: Int) -> CGFloat {
        CGFloat(sin(Double(phase) * .pi * 2 + Double(col) * 0.4))
    }

    private func run() {
        guard !reduceMotion else {
            phase = 0.35
            return
        }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }
}

// MARK: - All your devices

private struct DevicesArt: View {
    var reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            device(icon: "desktopcomputer", label: "Mac", wide: 86, tall: 58, delay: 0)
            device(icon: "ipad", label: "iPad", wide: 52, tall: 70, delay: 0.08)
            device(icon: "iphone", label: "Phone", wide: 34, tall: 62, delay: 0.16)
        }
        .onAppear { shown = true }
    }

    private func device(icon: String, label: String, wide: CGFloat, tall: CGFloat, delay: Double) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: wide, height: tall)
            Text(label)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
        }
        .offset(y: reduceMotion || shown ? 0 : 18)
        .opacity(reduceMotion || shown ? 1 : 0)
        .animation(
            .spring(response: 0.55, dampingFraction: 0.78).delay(reduceMotion ? 0 : delay),
            value: shown
        )
    }
}

// MARK: - Where it went

private struct SpendArt: View {
    var reduceMotion: Bool
    @State private var raised = false

    private let bars: [(CGFloat, Color)] = [
        (0.42, Color(red: 0xC3 / 255, green: 0xB0 / 255, blue: 0xFF / 255)),
        (0.72, Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)),
        (1.00, Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bar.1)
                        .frame(width: 28, height: 110 * bar.0 * (reduceMotion || raised ? 1 : 0.12))
                        .animation(
                            .spring(response: 0.7, dampingFraction: 0.78)
                                .delay(reduceMotion ? 0 : Double(index) * 0.1),
                            value: raised
                        )
                }
            }
        }
        .frame(height: 120, alignment: .bottom)
        .onAppear { raised = true }
    }
}

// MARK: - What is left

private struct RemainingArt: View {
    var reduceMotion: Bool
    @State private var trim: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.accent.opacity(0.16), lineWidth: 14)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(
                    AngularGradient(
                        colors: [Theme.accent, Theme.secondary, Theme.accent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("70%")
                    .font(ClientType.figureSmall)
                Text("left")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
        .onAppear {
            let end: CGFloat = 0.70
            if reduceMotion {
                trim = end
            } else {
                withAnimation(.easeOut(duration: 0.9)) { trim = end }
            }
        }
    }
}

// MARK: - Workspaces

private struct WorkspacesArt: View {
    var reduceMotion: Bool
    @State private var shown = false

    private let rows: [(indent: CGFloat, icon: String, name: String)] = [
        (0, "folder.fill", "project"),
        (18, "folder.fill", "src"),
        (36, "doc.text", "main.rs"),
        (18, "doc.text", "README.md"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 8) {
                    Image(systemName: row.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(row.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.leading, row.indent)
                .opacity(reduceMotion || shown ? 1 : 0)
                .offset(x: reduceMotion || shown ? 0 : -10)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.82)
                        .delay(reduceMotion ? 0 : Double(index) * 0.09),
                    value: shown
                )
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { shown = true }
    }
}

// MARK: - Sessions

private struct SessionsArt: View {
    var reduceMotion: Bool
    @State private var lines = 0
    @State private var blink = false

    private let script = [
        "$ claude",
        "reading src/main.rs",
        "patched the parser",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.danger.opacity(0.75)).frame(width: 7, height: 7)
                Circle().fill(Theme.warning.opacity(0.85)).frame(width: 7, height: 7)
                Circle().fill(Theme.accent.opacity(0.75)).frame(width: 7, height: 7)
                Spacer()
            }
            .padding(.bottom, 4)
            ForEach(Array(script.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(index == 0 ? Theme.accent : .primary)
                        .opacity(lines > index ? 1 : 0)
                    if lines == index + 1 {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 6, height: 12)
                            .opacity(reduceMotion || blink ? 1 : 0.15)
                            .padding(.leading, 3)
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
        .onAppear { run() }
    }

    private func run() {
        if reduceMotion {
            lines = script.count
            blink = true
            return
        }
        Task { @MainActor in
            for step in 1...script.count {
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeOut(duration: 0.2)) { lines = step }
            }
            withAnimation(.easeInOut(duration: 0.55).repeatForever()) {
                blink = true
            }
        }
    }
}

// MARK: - On the go

private struct OnTheGoArt: View {
    var reduceMotion: Bool
    @State private var pulse: CGFloat = 0

    var body: some View {
        HStack(spacing: 18) {
            tile(icon: "iphone", size: 36)
            ZStack {
                Capsule()
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 72, height: 4)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                    .offset(x: reduceMotion ? 0 : (pulse - 0.5) * 56)
            }
            .frame(width: 72)
            tile(icon: "laptopcomputer", size: 40)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
    }

    private func tile(icon: String, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accentSoft)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: size + 28, height: size + 28)
    }
}

// MARK: - We never see your files

private struct PrivacyArt: View {
    var reduceMotion: Bool
    @State private var locked = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accentSoft)
                .frame(width: 132, height: 132)
            Circle()
                .stroke(Theme.accent.opacity(0.28), lineWidth: 2)
                .frame(width: 132, height: 132)
                .scaleEffect(reduceMotion || locked ? 1 : 0.86)
            Image(systemName: locked || reduceMotion ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Theme.accent)
                .scaleEffect(reduceMotion || locked ? 1 : 0.88)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: locked)
        .onAppear {
            if reduceMotion {
                locked = true
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    locked = true
                }
            }
        }
    }
}

// MARK: - You are in control

private struct ControlArt: View {
    var reduceMotion: Bool
    @State private var shown = false

    private let rows: [(String, Bool)] = [
        ("Private account", true),
        ("Sync totals", false),
        ("Remote reach", false),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0)
                        .font(ClientType.label)
                    Spacer()
                    Capsule()
                        .fill(row.1 ? Theme.accent : Theme.border)
                        .frame(width: 40, height: 24)
                        .overlay(alignment: row.1 ? .trailing : .leading) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 18, height: 18)
                                .padding(3)
                        }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                }
                .opacity(reduceMotion || shown ? 1 : 0)
                .offset(y: reduceMotion || shown ? 0 : 10)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.84)
                        .delay(reduceMotion ? 0 : Double(index) * 0.08),
                    value: shown
                )
            }
        }
        .frame(maxWidth: 280)
        .onAppear { shown = true }
    }
}

#endif
