// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The Chat section, before there is a Chat.
///
/// A section with nothing behind it, on purpose. The place people would look
/// for it is worth marking before the feature exists, and an honest empty
/// screen is a better answer than a row that is not there yet. No button:
/// a Notify me that does nothing would be worse than nothing.
struct ChatComingSoonView: View {
    /// The folder this was opened from, when there is one to name. It makes
    /// the sentence about the work in front of somebody rather than about a
    /// feature in general.
    var folderName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ChatScene(reduceMotion: reduceMotion)
            Text("Chat is on the way")
                .font(Theme.title3.weight(.semibold))
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.l)
        .background(Theme.background)
        #if os(macOS)
        .navigationTitle("Chat")
        #endif
    }

    private var message: String {
        if let folderName, !folderName.isEmpty {
            return "A friendlier way to talk to the agents already running in \(folderName), without a terminal in between."
        }
        return "A friendlier way to talk to the agents already running in this folder, without a terminal in between."
    }
}

/// Four harness marks drifting around a chat bubble.
///
/// The rules `ClientEmptyArt` sets, kept here because both platforms draw this
/// one: brand strokes at one weight, one small loop, and a resting frame that
/// Reduce Motion lands on and stays at.
struct ChatScene: View {
    var reduceMotion: Bool

    /// The marks, and where each one rests. Angles rather than points, so the
    /// ring stays a ring at any size.
    private static let orbit: [(id: String, angle: Double)] = [
        ("claude_code", 210),
        ("grok", 330),
        ("antigravity", 30),
        ("cursor", 150),
    ]

    @State private var drifting = false

    var body: some View {
        ZStack {
            bubble
            ForEach(Array(Self.orbit.enumerated()), id: \.offset) { index, item in
                HarnessMark(id: item.id, size: 26)
                    .offset(offset(for: item.angle))
                    // Each mark on its own phase, so the four breathe against
                    // each other rather than pulsing as one object.
                    .opacity(drifting ? 1 : 0.72)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 2.4 + Double(index) * 0.35)
                                .repeatForever(autoreverses: true),
                        value: drifting
                    )
            }
        }
        .frame(width: 168, height: 120)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            drifting = true
        }
    }

    private var bubble: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.7)
            .frame(width: 62, height: 40)
            .overlay(alignment: .center) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle()
                            .fill(dot == 1 ? Theme.secondary : Theme.accent)
                            .frame(width: 5, height: 5)
                            .opacity(drifting ? 1 : 0.35)
                            .animation(
                                reduceMotion
                                    ? nil
                                    : .easeInOut(duration: 0.9)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(dot) * 0.18),
                                value: drifting
                            )
                    }
                }
            }
    }

    /// Where one mark sits, at rest and at the far end of its drift.
    private func offset(for angle: Double) -> CGSize {
        let radians = angle * .pi / 180
        let radius: CGFloat = drifting ? 56 : 50
        return CGSize(width: cos(radians) * radius, height: sin(radians) * radius * 0.62)
    }
}
