// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// A visible inspector and agent-follow observer share one discovery flight.
actor SimulatorInventory {
    static let shared = SimulatorInventory()
    private var cached: [SimulatorDevice] = []
    private var readAt = Date.distantPast
    private var flight: Task<[SimulatorDevice], Error>?
    func load(force: Bool = false) async throws -> [SimulatorDevice] {
        if !force, Date().timeIntervalSince(readAt) < 2 { return cached }
        if let flight { return try await flight.value }
        let task = Task {
            var devices: [SimulatorDevice] = []
            var appleError: Error?
            do { devices = try SimulatorDevice.appleInventory(await SimulatorCommand.simctl(["list", "devices", "available", "--json"])) }
            catch { appleError = error }
            if let android = AndroidSimulatorTools.installed() {
                if let extra = try? await android.inventory() { devices.append(contentsOf: extra) }
            }
            if devices.isEmpty, let appleError { throw appleError }
            return devices
        }
        flight = task
        defer { flight = nil }
        let result = try await task.value
        cached = result; readAt = Date()
        return result
    }
}

#endif
