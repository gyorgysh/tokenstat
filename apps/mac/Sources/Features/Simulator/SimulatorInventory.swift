// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// A visible inspector and agent-follow observer share one discovery flight.
actor SimulatorInventory {
    typealias Loader = @Sendable () async throws -> [SimulatorDevice]
    static let shared = SimulatorInventory()
    private let apple: Loader
    private let android: Loader
    private var lastApple: [SimulatorDevice] = []
    private var lastAndroid: [SimulatorDevice] = []
    private var cached: [SimulatorDevice] = []
    private var readAt = Date.distantPast
    private var flight: Task<[SimulatorDevice], Error>?
    init(apple: @escaping Loader = {
        try SimulatorDevice.appleInventory(await SimulatorCommand.simctl(["list", "devices", "available", "--json"]))
    }, android: @escaping Loader = {
        guard let tools = AndroidSimulatorTools.installed() else { return [] }
        return try await tools.inventory()
    }) {
        self.apple = apple; self.android = android
    }

    private static func discover(_ loader: Loader) async -> Result<[SimulatorDevice], Error> {
        do { return .success(try await loader()) } catch { return .failure(error) }
    }
    func load(force: Bool = false) async throws -> [SimulatorDevice] {
        try Task.checkCancellation()
        if !force, Date().timeIntervalSince(readAt) < 2 { return cached }
        if let flight {
            if !force { return try await flight.value }
            // An explicit attach may name a device created after this flight
            // began. Wait for it, then take a fresh snapshot for that request.
            _ = try? await flight.value
            try Task.checkCancellation()
            return try await load(force: true)
        }
        let task = Task {
            defer { flight = nil }
            async let appleFlight = Self.discover(apple)
            async let androidFlight = Self.discover(android)
            let (appleResult, androidResult) = await (appleFlight, androidFlight)
            // A tool failure says nothing about whether its devices stopped.
            // Preserve that platform's last successful inventory so refresh
            // cannot detach a live screen or mistake recovery for a new boot.
            if case .success(let devices) = appleResult { lastApple = devices }
            if case .success(let devices) = androidResult { lastAndroid = devices }
            let devices = lastApple + lastAndroid
            if devices.isEmpty, case .failure(let error) = appleResult { throw error }
            cached = devices; readAt = Date()
            return devices
        }
        flight = task
        return try await task.value
    }
}

#endif
