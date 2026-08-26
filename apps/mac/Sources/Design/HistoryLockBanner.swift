// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

extension Notification.Name {
    /// Open the in-app plan sheet. iOS only uses this. Mac keeps the website.
    static let tokenstatOpenPaywall = Notification.Name("ai.tokenstat.openPaywall")
    /// The signed-in account just changed tier or remote entitlement.
    /// Home and Devices refetch instead of keeping a Free lock on screen.
    static let tokenstatEntitlementDidChange = Notification.Name("ai.tokenstat.entitlementDidChange")
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

/// The same Free-year note the public profile puts under the heatmap.
///
/// Not a wall. The year is already on screen. This says why the older
/// squares are muted and offers the page that unlocks them.
struct HistoryLockBanner: View {
    /// How many recent days stay exact. Free is 30.
    var days: Int = 30


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            (
                Text("Older history is locked. ")
                    .font(Theme.font(12, weight: .semibold))
                + Text("Free shows the last \(days) days in full. Older days keep the year shape only.")
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
            )
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Link("Upgrade to see the year", destination: Plans.pricing)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .underline(false)
            #else
            Button("See plans", .plans) {
                NotificationCenter.default.post(name: .tokenstatOpenPaywall, object: nil)
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
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
