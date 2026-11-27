// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum PlanName {
    static func title(_ tier: String) -> String {
        switch tier.lowercased() {
        case "free": L10n.text("common.plan.free")
        case "supporter": L10n.text("common.plan.supporter")
        case "patron": L10n.text("common.plan.patron")
        case "legend": L10n.text("common.plan.legend")
        default: tier.capitalized
        }
    }
}
