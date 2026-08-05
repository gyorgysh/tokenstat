// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Provisions the tokenstat-owned host helper for the current macOS user.

import Foundation

#if os(macOS)
enum HostAgentInstaller {
    enum InstallerError: LocalizedError {
        case helperMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "The bundled tokenstat-hostd helper is not present in this build. Install the packaged app or build the host helper first."
            case let .commandFailed(message):
                return message
            }
        }
    }

    private static let label = "ai.tokenstat.hostd"

    static func installAndStart() throws {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("tokenstat", isDirectory: true)
        let binDirectory = applicationSupport.appendingPathComponent("bin", isDirectory: true)
        let helper = binDirectory.appendingPathComponent("tokenstat-hostd")
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        guard let bundled = bundledHelper else { throw InstallerError.helperMissing }
        if fileManager.fileExists(atPath: helper.path) {
            try fileManager.removeItem(at: helper)
        }
        try fileManager.copyItem(at: bundled, to: helper)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let launchAgents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/tokenstat", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)

        let plist = launchAgents.appendingPathComponent("\(label).plist")
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("hostd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("hostd.err.log").path
        ]
        (contents as NSDictionary).write(to: plist, atomically: true)

        let domain = "gui/\(getuid())"
        _ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
    }

    private static var bundledHelper: URL? {
        let candidates = [
            Bundle.main.url(forResource: "tokenstat-hostd", withExtension: nil),
            Bundle.main.privateFrameworksURL?.appendingPathComponent("tokenstat-hostd"),
            Bundle.main.resourceURL?.appendingPathComponent("tokenstat-hostd")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw InstallerError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "launchctl failed with status \(process.terminationStatus)."
                : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
#endif
