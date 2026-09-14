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
private struct OpenClientAccountKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openClientAccount: () -> Void {
        get { self[OpenClientAccountKey.self] }
        set { self[OpenClientAccountKey.self] = newValue }
    }
}

struct AvatarButton: View {
    @Environment(AccountModel.self) private var account

    var action: () -> Void

    /// The fetched picture, once it has arrived.
    ///
    /// This is *not* what the first frame reads. The toolbar is rebuilt on
    /// every navigation (each tab owns its chrome, and the sidebar layout
    /// re-keys the whole split on every selection), so a fresh button with an
    /// empty state is the common case, not the exception. Reading the shared
    /// cache synchronously in `displayImage` is what keeps an already fetched
    /// picture on screen instead of flashing the monogram while a new fetch
    /// spins up. See `Avatar`, which reads the same cache for the same reason.
    @State private var pictureImage: Image?

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
                        .font(Theme.fixed(drawn * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                    if let picture = displayImage {
                        // Over the monogram, not instead of it, so a slow or
                        // failed load shows the letter rather than a hole.
                        //
                        // Not `AsyncImage`. Every navigation builds a fresh
                        // button, and a fresh `AsyncImage` loads asynchronously
                        // even for a URL the system has cached, so each one
                        // painted its placeholder first: the picture blinking
                        // back to the letter on every tap. This reads the
                        // shared `AvatarCache` synchronously, so a picture
                        // fetched once stays painted on every later button.
                        picture
                            .resizable()
                            .scaledToFill()
                            .frame(width: drawn, height: drawn)
                            .clipShape(.circle)
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(Theme.fixed(drawn * 0.44, weight: .medium))
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
        .task(id: pictureRaw) {
            guard let raw = pictureRaw else {
                pictureImage = nil
                return
            }
            if let hit = AvatarCache.shared.cached(raw) {
                pictureImage = hit
                return
            }
            pictureImage = nil
            let loaded = await AvatarCache.shared.image(for: raw)
            guard !Task.isCancelled else { return }
            pictureImage = loaded
        }
    }

    private var signedIn: Bool { account.signedIn }

    /// The account's picture, already absolute by the time it reaches here.
    /// Blank is "no picture", same rule as `Avatar`.
    private var pictureRaw: String? {
        guard let raw = account.account?.avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// The fetched picture when one is on hand.
    ///
    /// The state's own image first, then the shared cache, read synchronously
    /// so a fresh button paints the picture on its first frame. A `.task` alone
    /// runs after that frame, which is exactly the one-frame monogram flash
    /// this exists to prevent.
    private var displayImage: Image? {
        if let pictureImage { return pictureImage }
        guard let raw = pictureRaw else { return nil }
        return AvatarCache.shared.cached(raw)
    }

    private var name: String { account.account?.title ?? "your account" }

    /// Initials from the display name, then the handle. Same function the
    /// website and the Mac `Avatar` use.
    private var monogram: String {
        Avatar.initials(from: account.account?.title)
            ?? Avatar.initials(from: account.account?.handle)
            ?? "t"
    }
}

#endif
