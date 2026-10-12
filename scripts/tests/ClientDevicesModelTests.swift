// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientDevicesModel.swift; no accounts or bridge calls.
import Foundation
struct Machine { var machineID: String?; var isHost = true }
struct MachineUsage { var machine: String; var valueMicros: Int64; var days = 30 }
enum WorkReference { typealias Scope = String }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? = "first" }
enum DeviceHistory { static func windowPhrase(days: Int) -> String { "\(days)" } }
extension Int64 { func saturatingAdd(_ other: Int64) -> Int64 { let (sum, overflow) = addingReportingOverflow(other); return overflow ? (other >= 0 ? .max : .min) : sum } }
@MainActor enum Bridge {
    static var pending: [CheckedContinuation<[MachineUsage], Error>] = []
    static func machineUsage(machines: [String], days: Int) async throws -> [MachineUsage] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
@main struct ClientDevicesModelTests {
    @MainActor static func waitFor(_ count: Int) async { while Bridge.pending.count < count { await Task.yield() } }
    @MainActor static func main() async {
        let model = ClientDevicesModel()
        let machine = Machine(machineID: "host")
        let older = Task { await model.load(machines: [machine], days: 30) }
        await waitFor(1)
        let newer = Task { await model.load(machines: [machine], days: 365) }
        await waitFor(2)
        Bridge.pending[1].resume(returning: [.init(machine: "host", valueMicros: 20, days: 365)])
        await newer.value
        Bridge.pending[0].resume(returning: [.init(machine: "host", valueMicros: 1)])
        await older.value
        assert(model.rows.first?.valueMicros == 20 && !model.isLoading)
        Bridge.pending = []
        let stale = Task { await model.load(machines: [machine], force: true) }
        await waitFor(1)
        await model.load(machines: [])
        Bridge.pending[0].resume(returning: [.init(machine: "host", valueMicros: 30)])
        await stale.value
        assert(model.rows.isEmpty && !model.isLoading)
        Bridge.pending = []
        let previousAccount = Task { await model.load(machines: [machine]) }
        await waitFor(1)
        WorkSessionContext.shared.scope = "second"
        let currentAccount = Task { await model.load(machines: [machine]) }
        await waitFor(2)
        Bridge.pending[0].resume(throwing: NSError(domain: "old account", code: 1))
        await previousAccount.value
        assert(model.errorMessage == nil && model.isLoading)
        Bridge.pending[1].resume(returning: [.init(machine: "host", valueMicros: .max), .init(machine: "other", valueMicros: 1)])
        await currentAccount.value
        assert(model.total == .max && !model.isLoading)
        print("ClientDevicesModel: stale window, removal, account switch, saturation passed")
    }
}
