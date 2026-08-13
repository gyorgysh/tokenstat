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

    /// Bring the agent up without a full reinstall when the helper is already
    /// on disk.
    ///
    /// A cold app used to call `installAndStart` whenever the socket was quiet,
    /// which always copied the binary and ran `bootout`/`bootstrap`. That is
    /// correct for a missing install, and wrong for the ordinary case where
    /// launchd is simply still starting the agent after login. Kickstarting
    /// the loaded job (or bootstrapping the existing plist once) is enough,
    /// and it avoids thrashing a daemon that owns live terminals.
    static func ensureRunning() throws {
        let fileManager = FileManager.default
        guard let helper = installedHelper, fileManager.isExecutableFile(atPath: helper.path) else {
            try installAndStart()
            return
        }
        let plist = launchAgentPlistURL
        if !fileManager.fileExists(atPath: plist.path) {
            try installAndStart()
            return
        }
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        // Already loaded and running the copy this app manages: ask launchd to
        // start it. No `-k`, so a running host is left alone rather than
        // killed and restarted.
        if let printed = try? run("/bin/launchctl", ["print", service]),
           printed.contains(helper.path)
        {
            _ = try? run("/bin/launchctl", ["kickstart", service])
            return
        }
        // Nothing loaded, or the loaded job runs some other copy (an earlier
        // install at another path). Tear down a stale registration and load
        // the plist this app owns.
        _ = try? run("/bin/launchctl", ["bootout", service])
        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
    }

    /// Install the helper and (re)load the launch agent.
    ///
    /// Copies only when the installed binary differs from the one in this
    /// bundle, and prefers `kickstart` over `bootout`/`bootstrap` when the
    /// job is already loaded and matches the plist on disk. A full tear-down
    /// is reserved for a first install, a changed plist, or a job definition
    /// launchd is still running from an older install at another path.
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
        let helperChanged = replaceHelperIfNeeded(from: bundled, to: helper, fileManager: fileManager)

        let launchAgents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/tokenstat", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        #if os(macOS)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        for name in ["hostd.out.log", "hostd.err.log"] {
            let file = logs.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: file.path) {
                fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        #endif

        let plist = launchAgents.appendingPathComponent("\(label).plist")
        // ProcessType is Interactive on purpose. Background throttles the
        // whole process tree (measured ~5s Claude first paint under hostd vs
        // ~0.3s for the same binary in a normal shell). The daemon owns live
        // terminals the user types into, so it is not a pure background job.
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appendingPathComponent("hostd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("hostd.err.log").path
        ]
        let plistChanged = writePlistIfNeeded(contents, to: plist)

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        let printed = try? run("/bin/launchctl", ["print", service])
        let alreadyLoaded = printed != nil
        let loadedRunsManagedHelper = printed?.contains(helper.path) == true

        if alreadyLoaded && !plistChanged && loadedRunsManagedHelper {
            if helperChanged {
                // Same job definition, new binary: `-k` replaces the process
                // without unloading the job, which is gentler than bootout and
                // keeps the KeepAlive policy intact.
                _ = try? run("/bin/launchctl", ["kickstart", "-k", service])
            } else {
                // Same binary, same job definition: just make sure it is running.
                _ = try? run("/bin/launchctl", ["kickstart", service])
            }
            return
        }

        if alreadyLoaded {
            // The loaded definition is stale: the plist on disk changed, or
            // the job runs a binary this app does not manage (an earlier
            // install at another path). `kickstart -k` would only restart the
            // process under that stale definition, so unload the job and load
            // the plist. The daemon owns live terminals either way: replacing
            // it means restarting it.
            _ = try? run("/bin/launchctl", ["bootout", service])
            try run("/bin/launchctl", ["bootstrap", domain, plist.path])
            return
        }

        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
    }

    /// Reinstall the helper when this build carries a different one.
    ///
    /// The daemon outlives the app: launchd keeps it running, so a copy
    /// installed weeks ago answers a window opened today, and a fix shipped in
    /// the app never reaches the process that needed it. That failure is
    /// silent, which is the worst part of it. Called on launch, and it does
    /// nothing at all in the ordinary case where the two already match: same
    /// bytes, same version, and launchd running the copy this app manages.
    static func refreshIfStale() {
        guard let bundled = bundledHelper, let installed = installedHelper else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.path) else { return }
        guard helpersDiffer(bundled, installed, manager: manager) else {
            // Same binary, but launchd may still be running an old job
            // definition that points somewhere else (an earlier install at
            // another path). Reload so the daemon answering the socket is the
            // one this app manages.
            let service = "gui/\(getuid())/\(label)"
            if let printed = try? run("/bin/launchctl", ["print", service]),
               printed.contains(installed.path)
            {
                return
            }
            try? installAndStart()
            return
        }
        try? installAndStart()
    }

    private static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private static var installedHelper: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appendingPathComponent("tokenstat/bin/tokenstat-hostd")
    }

    private static var bundledHelper: URL? {
        let candidates = [
            Bundle.main.url(forResource: "tokenstat-hostd", withExtension: nil),
            Bundle.main.privateFrameworksURL?.appendingPathComponent("tokenstat-hostd"),
            Bundle.main.resourceURL?.appendingPathComponent("tokenstat-hostd")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Copy the bundled helper over the installed one only when they differ.
    @discardableResult
    private static func replaceHelperIfNeeded(
        from bundled: URL,
        to helper: URL,
        fileManager: FileManager
    ) -> Bool {
        if fileManager.fileExists(atPath: helper.path),
           !helpersDiffer(bundled, helper, manager: fileManager)
        {
            return false
        }
        if fileManager.fileExists(atPath: helper.path) {
            try? fileManager.removeItem(at: helper)
        }
        do {
            try fileManager.copyItem(at: bundled, to: helper)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            return true
        } catch {
            return true
        }
    }

    /// Size and modification date first, then the binaries' own versions:
    /// free on every launch, and the two files are either the same copy or
    /// they are not.
    ///
    /// The filesystem check is trusted when it disagrees. When it reports the
    /// files are identical, a rebuild can still have reproduced both (same
    /// size, or packaging that copied a timestamp), so the binaries are asked
    /// for their version before two files are declared the same copy. Only a
    /// *newer* bundled helper counts as different. An older bundle must not
    /// roll a newer daemon back.
    private static func helpersDiffer(_ a: URL, _ b: URL, manager: FileManager) -> Bool {
        let attributes: (URL) -> (Int, Date)? = { url in
            guard let values = try? manager.attributesOfItem(atPath: url.path),
                  let size = values[.size] as? Int,
                  let modified = values[.modificationDate] as? Date
            else { return nil }
            return (size, modified)
        }
        guard let left = attributes(a), let right = attributes(b) else { return true }
        if left.0 != right.0 || left.1 != right.1 { return true }
        return isVersionNewer(version(of: a), than: version(of: b))
    }

    /// The version a hostd reports when run with the version flag, for
    /// example "tokenstat-hostd 0.2.8". Nil when the binary will not run or
    /// prints nothing parseable.
    private static func version(of url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        guard let output = try? run(url.path, ["--version"]) else { return nil }
        return output.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    /// True when `a` names a newer release than `b` (`0.2.8` > `0.2.7`).
    ///
    /// Numeric comparison of dotted parts, padded with zeros on the short
    /// side. A prerelease suffix compares by its numeric part, so a release
    /// is never replaced by an older build that merely claims the same
    /// numbers.
    private static func isVersionNewer(_ a: String?, than b: String?) -> Bool {
        guard let a, let b else { return false }
        let left = versionNumbers(a)
        let right = versionNumbers(b)
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func versionNumbers(_ raw: String) -> [UInt64] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let withoutV = trimmed.first == "v" || trimmed.first == "V"
            ? String(trimmed.dropFirst())
            : trimmed
        let numeric = withoutV.split(separator: "-").first.map(String.init) ?? withoutV
        return numeric.split(separator: ".").map { UInt64($0) ?? 0 }
    }

    /// Write the plist only when its contents actually changed, so a no-op
    /// install does not touch the file and re-trigger launchd bookkeeping.
    private static func writePlistIfNeeded(_ contents: [String: Any], to plist: URL) -> Bool {
        let next = contents as NSDictionary
        if let existing = NSDictionary(contentsOf: plist), existing.isEqual(to: next) {
            return false
        }
        next.write(to: plist, atomically: true)
        return true
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
