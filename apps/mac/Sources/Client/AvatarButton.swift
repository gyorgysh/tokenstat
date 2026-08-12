// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only. The Mac has `RootView`, and these
// screens lean on toolbar placements and a tab bar that macOS does not
// have, so compiling them there would only break the desktop build.
#if !os(macOS)

/// The account, reached from the leading edge of every screen.
///
/// The picture when there is one, the monogram when there is not.
///
/// The monogram was all this ever drew, on the strength of a stale comment in
/// `Models.swift` saying `/api/v1/me` carried no avatar. It does: the API sends
/// `/avatar/<name>`, relative so it never hands out a third-party URL, and
/// `tokenstat-host` already resolves it against the host it authenticated to.
/// The field was populated the whole time and nothing was reading it.
///
/// The monogram stays as the placeholder and the failure case, for the reason
/// `HarnessMark` keeps its letter tile: a wrong picture is worse than no
/// picture, and a broken image is worse than both.
///
/// Signed out it is a person glyph inside an accent ring, which is the state
/// most in need of an affordance: an empty app with no visible way in is an app
/// people delete.
struct AvatarButton: View {
    @Environment(AccountModel.self) private var account

    var action: () -> Void

    /// The toolbar's own metric, and the whole item.
    ///
    /// This used to draw at 30 inside a 44pt frame, on the reasoning that 44 is
    /// the minimum a finger can be asked to hit. In a toolbar that is the wrong
    /// place to enforce it: the bar sizes its item to the frame and draws its
    /// own container around it, so a 30pt circle in a 44pt item is 7pt of dead
    /// space on every side. The picture reads as inset and sits off the leading
    /// edge everything else on the screen lines up with. The bar already gives
    /// its items a comfortable hit area, and `contentShape` makes the whole
    /// circle count.
    private let drawn: CGFloat = 34

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.secondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(signedIn ? 1 : 0.14)
                if signedIn {
                    Text(monogram)
                        .font(.system(size: drawn * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if let picture {
                        // Over the monogram, not instead of it, so a slow or
                        // failed load shows the letter rather than a hole. The
                        // system caches the response, so this is one fetch per
                        // launch and not one per screen that draws an avatar.
                        AsyncImage(url: picture) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: drawn, height: drawn)
                        .clipShape(.circle)
                        .transition(.opacity)
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: drawn * 0.44, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                Circle()
                    .strokeBorder(Theme.accent.opacity(signedIn ? 0 : 0.55), lineWidth: 1.5)
            }
            .frame(width: drawn, height: drawn)
            // The circle, not its bounding box. A rect content shape on a
            // round control claims the corners it does not draw, which in a
            // toolbar means swallowing taps meant for what sits beside it.
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(signedIn ? "Account, \(name)" : "Sign in to tokenstat")
        .accessibilityHint("Opens your account")
    }

    private var signedIn: Bool { account.signedIn }

    /// The account's picture, already absolute by the time it reaches here.
    private var picture: URL? {
        guard let raw = account.account?.avatar, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var name: String { account.account?.title ?? "your account" }

    /// One letter, uppercased, from the display name or the handle. A name that
    /// begins with an emoji or a non-Latin script keeps its own first
    /// character, which is the right monogram for that person and not a
    /// question mark.
    private var monogram: String {
        guard let first = account.account?.title?.trimmingCharacters(in: .whitespaces).first else {
            return "t"
        }
        return String(first).uppercased()
    }
}

#endif
