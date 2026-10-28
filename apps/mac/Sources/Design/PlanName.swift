// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// What a plan is called where a person reads it.
///
/// The account server and the stores keep their original keys (`supporter`,
/// `patron`, `legend`) because product ids and existing subscriptions depend
/// on them. The names people see are Plus, Pro and Elite, so a tier key must
/// never be capitalized into a label: it goes through here.
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
