// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with DevicePresenceOrder.swift.
import Foundation

@main struct DevicePresenceOrderTests {
    static func main() {
        func row(_ id: String, current: Bool = false, online: Bool = false, time: Double = 0, name: String = "Device") -> DevicePresenceOrder {
            DevicePresenceOrder(isCurrent: current, online: online, lastActive: Date(timeIntervalSince1970: time), name: name, id: id)
        }
        let rows = [row("old"), row("recent", time: 10), row("online", online: true), row("current", current: true)]
        assert(rows.sorted().map(\.id) == ["current", "online", "recent", "old"])
        assert([row("b"), row("a")].sorted().map(\.id) == ["a", "b"])
        assert(row("a", name: "alpha") < row("b", name: "Beta"))
        for a in rows { for b in rows { assert(!(a < b && b < a)) } }
        print("Device presence order tests passed")
    }
}
