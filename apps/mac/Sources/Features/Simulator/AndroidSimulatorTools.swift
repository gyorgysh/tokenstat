// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation
import CoreGraphics

struct AndroidSimulatorTools: Sendable {
    let root: URL
    var adb: String { root.appendingPathComponent("platform-tools/adb").path }
    var emulator: String { root.appendingPathComponent("emulator/emulator").path }
    static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        let candidates: [String?] = [environment["ANDROID_SDK_ROOT"], environment["ANDROID_HOME"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path]
        return candidates.compactMap { $0 }.map { Self(root: URL(fileURLWithPath: $0)) }
            .first { FileManager.default.isExecutableFile(atPath: $0.adb) && FileManager.default.isExecutableFile(atPath: $0.emulator) }
    }
    static func validAVD(_ name: String) -> Bool {
        SimulatorDevice.validAndroidName(name)
    }
    static func naturalLandscape(_ output: String) -> Bool? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Physical size:") || $0.hasPrefix("Override size:") }),
              let value = line.split(separator: ":").last else { return nil }
        let dimensions = value.trimmingCharacters(in: .whitespaces).split(separator: "x")
        guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]), width > 0, height > 0 else { return nil }
        return width > height
    }
    static func rotation(_ orientation: Int, naturalLandscape: Bool) -> Int {
        let portraitBased = orientation == 3 ? 1 : orientation == 4 ? 3 : orientation == 2 ? 2 : 0
        return naturalLandscape ? (portraitBased + 1) % 4 : portraitBased
    }
    static func emulatorSerials(_ output: String) -> [String] {
        emulatorTargets(output).map(\.serial)
    }
    static func emulatorTargets(_ output: String) -> [(serial: String, transportID: UInt64?)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device", fields[0].hasPrefix("emulator-"),
                  fields[0].dropFirst(9).allSatisfy(\.isNumber), fields[0].count > 9 else { return nil }
            let field = fields.first { $0.hasPrefix("transport_id:") }
            let transport = field.flatMap { UInt64($0.dropFirst(13)) }
            if field != nil && (transport == nil || transport == 0) { return nil }
            return (String(fields[0]), transport)
        }
    }
    /// An emulator port can be reused by another AVD after a restart. ADB's
    /// transport identity pins the connection instead of retargeting that port.
    static func targetArguments(_ serial: String, transportID: UInt64?) -> [String] {
        transportID.map { ["-t", String($0)] } ?? ["-s", serial]
    }
    func inventory() async throws -> [SimulatorDevice] {
        async let avds = SimulatorCommand.run(emulator, ["-list-avds"])
        async let connected = SimulatorCommand.run(adb, ["devices", "-l"])
        let (names, running) = try await (avds, connected)
        guard names.status == 0 else { throw SimulatorCommand.Failure(message: names.errors) }
        guard running.status == 0 else { throw SimulatorCommand.Failure(message: running.errors) }
        var serials: [String: String] = [:]
        var transports: [String: UInt64] = [:]
        for (serial, transport) in Self.emulatorTargets(String(decoding: running.data, as: UTF8.self)) {
            guard let transport else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.android_tools_update")) }
            let result = try await SimulatorCommand.run(adb, Self.targetArguments(serial, transportID: transport) + ["emu", "avd", "name"], timeout: 4)
            guard result.status == 0 else { throw SimulatorCommand.Failure(message: result.errors) }
            if let name = String(decoding: result.data, as: UTF8.self).split(whereSeparator: \.isNewline).first {
                serials[String(name)] = serial
                transports[String(name)] = transport
            }
        }
        return String(decoding: names.data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).filter(Self.validAVD).map { name in
            let base = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
            let config = (try? String(contentsOf: base.appendingPathComponent(name + ".avd/config.ini"), encoding: .utf8)) ?? ""
            var values: [String: String] = [:]
            for line in config.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            let device = values["hw.device.name"] ?? name
            let api = values["image.sysdir.1"]?.split(separator: "/").first(where: { $0.hasPrefix("android-") })?.dropFirst(8)
            return SimulatorDevice(id: "android:" + name, name: values["avd.ini.displayname"] ?? name,
                runtime: api.map { "Android · API " + $0 } ?? "Android", platform: .android,
                deviceType: device, isBooted: serials[name] != nil, serial: serials[name], transportID: transports[name])
        }
    }
    func command(_ serial: String, _ arguments: [String], timeout: TimeInterval = 15, transportID: UInt64? = nil) async throws -> Data {
        let result = try await SimulatorCommand.run(adb, Self.targetArguments(serial, transportID: transportID) + arguments, timeout: timeout)
        guard result.status == 0 else { throw SimulatorCommand.Failure(message: result.errors) }
        return result.data
    }
    /// adb's remote shell joins arguments again, so quote user text at that boundary.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func gestureArguments(from: CGPoint, to: CGPoint, duration: TimeInterval) -> [String] {
        if hypot(from.x - to.x, from.y - to.y) < 8 && duration < 0.5 {
            return ["shell", "input", "tap", String(Int(to.x)), String(Int(to.y))]
        }
        return ["shell", "input", "swipe", String(Int(from.x)), String(Int(from.y)), String(Int(to.x)), String(Int(to.y)), String(min(1500, max(50, Int(duration * 1000))))]
    }
}

actor AndroidSimulatorLauncher {
    static let shared = AndroidSimulatorLauncher()
    private var processes: [String: Process] = [:]
    func boot(_ name: String, tools: AndroidSimulatorTools) throws {
        try Task.checkCancellation()
        guard AndroidSimulatorTools.validAVD(name) else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.device_missing")) }
        if processes[name]?.isRunning == true { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.emulator)
        process.arguments = ["-avd", name, "-no-window", "-no-boot-anim"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes[name] = process
    }
}
#endif
