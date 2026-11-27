// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only. The Mac has `RootView`, and these
// screens lean on toolbar placements and a tab bar that macOS does not
// have, so compiling them there would only break the desktop build.
#if !os(macOS)

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

    var plainBadge: Bool = false

    var action: () -> Void

    @State private var pictureImage: Image?
    @State private var pictureURL: String?

    private var tier: String? {
        guard signedIn, let value = account.account?.tier?.trimmingCharacters(in: .whitespacesAndNewlines),
              BadgeShape(tier: value) != nil else { return nil }
        return value.lowercased()
    }

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
            .frame(width: 40, height: 40)
            .overlay(alignment: .bottomTrailing) {
                if let tier {
                    if plainBadge {
                        TierMark(tier: tier, size: 12)
                            .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                    } else {
                        TierMark(tier: tier, size: 10)
                            .frame(width: 16, height: 16)
                            .background(Theme.panel, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                            .accessibilityHidden(true)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if account.isSyncing {
                    Circle().fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(ClientAccountButtonStyle(showsPlan: tier != nil, showsRing: !plainBadge))
        .accessibilityLabel(tier.map { L10n.text("apple.avatarbutton.account_plan", name, PlanName.title($0)) }
            ?? (signedIn ? L10n.text("apple.avatarbutton.account_0.1342b321", "\(name)") : L10n.text("apple.avatarbutton.sign_in_to_tokenstat.9a950fc4")))
        .accessibilityHint(L10n.text("apple.avatarbutton.opens_your_account.bf04ed9e"))
        .task(id: pictureRaw) {
            pictureURL = pictureRaw
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
            guard !Task.isCancelled, pictureRaw == raw else { return }
            pictureImage = loaded
        }
    }

    private var signedIn: Bool { account.signedIn }

    private var pictureRaw: String? {
        guard let raw = account.account?.avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private var displayImage: Image? {
        guard let raw = pictureRaw else { return nil }
        if pictureURL == raw, let pictureImage { return pictureImage }
        return AvatarCache.shared.cached(raw)
    }

    private var name: String { account.account?.title ?? L10n.text("apple.avatarbutton.your_account.17a7e5cf") }

    private var monogram: String {
        Avatar.initials(from: account.account?.title)
            ?? Avatar.initials(from: account.account?.handle)
            ?? "t"
    }
}

private struct ClientAccountButtonStyle: ButtonStyle {
    let showsPlan: Bool
    let showsRing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if showsPlan {
                    Circle().strokeBorder(Theme.border.opacity(showsRing ? 1 : 0), lineWidth: 1)
                        .overlay {
                            Circle()
                                .strokeBorder(AngularGradient(colors: [Theme.accent, Theme.secondary, Theme.accent], center: .center), lineWidth: 1.5)
                                .rotationEffect(.degrees(configuration.isPressed && !reduceMotion ? 120 : 0))
                                .opacity(configuration.isPressed ? 1 : 0)
                                .shadow(color: Theme.secondary.opacity(configuration.isPressed ? 0.22 : 0), radius: 3)
                        }
                        .frame(width: 38, height: 38)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: configuration.isPressed)
    }
}

#endif
