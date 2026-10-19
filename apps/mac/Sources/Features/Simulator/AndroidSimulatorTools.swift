// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

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
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device", fields[0].hasPrefix("emulator-"),
                  fields[0].dropFirst(9).allSatisfy(\.isNumber), fields[0].count > 9 else { return nil }
            return String(fields[0])
        }
    }
    func inventory() async throws -> [SimulatorDevice] {
        async let avds = SimulatorCommand.run(emulator, ["-list-avds"])
        async let connected = SimulatorCommand.run(adb, ["devices"])
        let (names, running) = try await (avds, connected)
        guard names.status == 0, running.status == 0 else { return [] }
        var serials: [String: String] = [:]
        for serial in Self.emulatorSerials(String(decoding: running.data, as: UTF8.self)) {
            let result = try await SimulatorCommand.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 4)
            if result.status == 0, let name = String(decoding: result.data, as: UTF8.self).split(whereSeparator: \.isNewline).first {
                serials[String(name)] = serial
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
                deviceType: device, isBooted: serials[name] != nil, serial: serials[name])
        }
    }
    func command(_ serial: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> Data {
        let result = try await SimulatorCommand.run(adb, ["-s", serial] + arguments, timeout: timeout)
        guard result.status == 0 else { throw SimulatorCommand.Failure(message: result.errors) }
        return result.data
    }
    /// adb's remote shell joins arguments again, so quote user text at that boundary.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

actor AndroidSimulatorLauncher {
    static let shared = AndroidSimulatorLauncher()
    private var processes: [String: Process] = [:]
    func boot(_ name: String, tools: AndroidSimulatorTools) throws {
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
