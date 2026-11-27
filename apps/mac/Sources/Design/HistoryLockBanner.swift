// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

extension Notification.Name {
    /// Open the in-app plan sheet. iOS only uses this. Mac keeps the website.
    static let tokenstatOpenPaywall = Notification.Name("ai.tokenstat.openPaywall")
    /// The signed-in account just changed tier or remote entitlement.
    /// Home and Devices refetch instead of keeping a Free lock on screen.
    static let tokenstatEntitlementDidChange = Notification.Name("ai.tokenstat.entitlementDidChange")
    static let tokenstatDidSync = Notification.Name("ai.tokenstat.didSync")
}

/// Where "See plans" goes, which is not the same place on the two platforms.
///
/// The Mac sends people to the website, because a Mac plan is not an Apple
/// purchase. iOS has to use the in-app paywall, because an Apple subscription
/// cannot be sold through a link out of the app. One place that knows which,
/// so a new call site cannot get it backwards and ship a button that opens
/// Safari on a phone.
@MainActor
enum Plans {
    static let pricing = URL(string: "https://tokenstat.ai/pricing")!

    static func open(using openURL: OpenURLAction) {
        #if os(macOS)
        openURL(pricing)
        #else
        NotificationCenter.default.post(name: .tokenstatOpenPaywall, object: nil)
        #endif
    }
}

struct HistoryLockBanner: View {
    var days: Int = 30


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            (
                Text(L10n.text("apple.historylockbanner.older_history_is_locked.8ef6b29a"))
                    .font(Theme.font(12, weight: .semibold))
                + Text(L10n.text("apple.historylockbanner.free_shows_the_last_0_days_in_full_older_d.2a97306a", "\(days)"))
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
            )
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Link(L10n.text("apple.historylockbanner.upgrade_to_see_the_year.7918f544"), destination: Plans.pricing)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .underline(false)
            #else
            Button(L10n.text("apple.historylockbanner.see_plans.d9898933"), .plans) {
                NotificationCenter.default.post(name: .tokenstatOpenPaywall, object: nil)
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(QuietLinkStyle())
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
