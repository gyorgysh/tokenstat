// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// A visible inspector and agent-follow observer share one discovery flight.
actor SimulatorInventory {
    struct Snapshot: Sendable {
        let devices: [SimulatorDevice]
        let setup: SimulatorSetupState
    }
    typealias Loader = @Sendable () async throws -> [SimulatorDevice]
    static let shared = SimulatorInventory()
    private let apple: Loader
    private let android: Loader
    private var lastApple: [SimulatorDevice] = []
    private var lastAndroid: [SimulatorDevice] = []
    private var cached = Snapshot(devices: [], setup: SimulatorSetupState())
    private var readAt = Date.distantPast
    private var flight: Task<Snapshot, Never>?
    init(apple: @escaping Loader = {
        do { _ = try await SimulatorCommand.developerDirectory() }
        catch { throw SimulatorSetupIssue.missingXcode }
        return try SimulatorDevice.appleInventory(await SimulatorCommand.simctl(["list", "devices", "available", "--json"]))
    }, android: @escaping Loader = {
        guard let tools = AndroidSimulatorTools.installed() else { throw SimulatorSetupIssue.missingAndroidSDK }
        return try await tools.inventory()
    }) {
        self.apple = apple; self.android = android
    }

    private static func discover(_ loader: Loader) async -> Result<[SimulatorDevice], Error> {
        do { return .success(try await loader()) } catch { return .failure(error) }
    }
    func load(force: Bool = false) async throws -> [SimulatorDevice] {
        let snapshot = try await inspect(force: force)
        if snapshot.devices.isEmpty, let message = snapshot.setup.apple.failure ?? snapshot.setup.android.failure {
            throw SimulatorCommand.Failure(message: message)
        }
        return snapshot.devices
    }
    func inspect(force: Bool = false) async throws -> Snapshot {
        try Task.checkCancellation()
        if !force, Date().timeIntervalSince(readAt) < 2 { return cached }
        if let flight {
            if !force { return await flight.value }
            // An explicit attach may name a device created after this flight
            // began. Wait for it, then take a fresh snapshot for that request.
            _ = await flight.value
            try Task.checkCancellation()
            return try await inspect(force: true)
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
            let snapshot = Snapshot(devices: devices,
                setup: SimulatorSetupState(apple: SimulatorSetupState.status(appleResult), android: SimulatorSetupState.status(androidResult)))
            cached = snapshot; readAt = Date()
            return snapshot
        }
        flight = task
        return await task.value
    }
}

#endif
