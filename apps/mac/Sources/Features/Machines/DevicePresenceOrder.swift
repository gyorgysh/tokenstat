// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// A deterministic presence order, independent of device type or spend.
struct DevicePresenceOrder: Comparable {
    let isCurrent: Bool
    let online: Bool
    let lastActive: Date
    let name: String
    let id: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        if lhs.online != rhs.online { return lhs.online }
        if lhs.lastActive != rhs.lastActive { return lhs.lastActive > rhs.lastActive }
        let names = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if names != .orderedSame { return names == .orderedAscending }
        return lhs.id < rhs.id
    }
}
