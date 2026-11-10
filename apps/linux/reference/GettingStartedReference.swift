// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Compile the actual card with inert rendering dependencies. L10n returns the
// keys so this compares branching independently of translated text. The test
// harness exposes the card's private steps property; no host or window opens.
import SwiftUI
import Foundation

enum Theme {
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 20 }
    static let panel = Color.clear, accent = Color.accentColor
    static let cardRadius: CGFloat = 14
    static let title3 = Font.system(size: 15)
    static let headline = Font.system(size: 13)
    static let callout = Font.system(size: 12)
}
enum L10n { static func text(_ key: String) -> String { key } }
enum GettingStartedState: String { case done, now, next }
enum ActionIcon { case refresh, signIn, next }
struct GettingStartedStep: Identifiable {
    let number: Int
    let title: String
    let body: String
    let state: GettingStartedState
    var actionTitle: String?
    var actionIcon: ActionIcon = .next
    var action: (() -> Void)?
    var id: Int { number }
}
struct GettingStartedRail: View { let steps: [GettingStartedStep]; var body: some View { EmptyView() } }
struct GettingStartedGhostGrid: View { var weeks: Int; var body: some View { EmptyView() } }
struct FeatureMark: View { var name: String; var tint: Color; var size: CGFloat; var body: some View { EmptyView() } }
struct ThemeRule: View { var body: some View { EmptyView() } }

@main struct GettingStartedReference {
    static func main() throws {
        var rows = [[String: Any]]()
        for signed in [false, true] {
            for scanning in [false, true] {
                for cooldown in [false, true] {
                    var scanCalls = 0
                    var signInCalls = 0
                    let card = GettingStartedCard(signedIn: signed, isScanning: scanning,
                        isCoolingDown: cooldown, onSignIn: { signInCalls += 1 }, onScan: { scanCalls += 1 })
                    let steps = card.steps.map { step -> [String: Any] in
                        step.action?()
                        let action: String?
                        if step.action == nil { action = nil }
                        else if step.actionIcon == .refresh && step.actionTitle == "apple.gettingstartedcard.scan_now.c01d65df" { action = "scan" }
                        else if step.actionIcon == .signIn && step.actionTitle == "common.sign_in" { action = "signIn" }
                        else { action = "unexpected" }
                        return ["number":step.number,"state":step.state.rawValue,"titleKey":step.title,
                                "bodyKey":step.body,"action":action as Any? ?? NSNull()]
                    }
                    precondition(scanCalls == (scanning || cooldown ? 0 : 1))
                    precondition(signInCalls == (signed ? 0 : 1))
                    rows.append(["signedIn":signed,"scanning":scanning,"coolingDown":cooldown,"steps":steps])
                }
            }
        }
        let output = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
