// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Provisions the tokenstat-owned host helper for the current macOS user.

import Foundation

#if os(macOS)
enum HostAgentInstaller {
    enum InstallerError: LocalizedError {
        case helperMissing
        case newerHelper
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "The bundled tokenstat-hostd helper is not present in this build. Install the packaged app or build the host helper first."
            case .newerHelper:
                return "A newer version of tokenstat manages the local helper. Open the latest app to change it."
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
        guard !hasNewerHelper else { throw InstallerError.newerHelper }
        let fileManager = FileManager.default
        guard let helper = installedHelper, fileManager.isExecutableFile(atPath: helper.path) else {
            try installAndStart()
            return
        }
        if fileManager.fileExists(atPath: restartMarker(for: helper).path) {
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
        // the plist this app owns. RunAtLoad is off when Always-on is off,
        // so bootstrap alone does not start the process.
        _ = try? run("/bin/launchctl", ["bootout", service])
        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
        _ = try? run("/bin/launchctl", ["kickstart", service])
    }

    /// Install the helper and (re)load the launch agent.
    ///
    /// Copies only when the installed binary differs from the one in this
    /// bundle, and prefers `kickstart` over `bootout`/`bootstrap` when the
    /// job is already loaded and matches the plist on disk. A full tear-down
    /// is reserved for a first install, a changed plist, or a job definition
    /// launchd is still running from an older install at another path.
    static func installAndStart() throws {
        guard !hasNewerHelper else { throw InstallerError.newerHelper }
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
        let helperChanged = try replaceHelperIfNeeded(from: bundled, to: helper, fileManager: fileManager)
        let marker = restartMarker(for: helper)
        let needsRestart = helperChanged || fileManager.fileExists(atPath: marker.path)

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
        let alwaysOn = resolvedAlwaysOn()
        // ProcessType stays Interactive either way. Background throttles a
        // live terminal. KeepAlive and RunAtLoad are the always-on switch:
        // off, the helper dies with the app and does not start at login.
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "KeepAlive": alwaysOn,
            "RunAtLoad": alwaysOn,
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appendingPathComponent("hostd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("hostd.err.log").path
        ]
        let plistChanged = try writePlistIfNeeded(contents, to: plist)

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        let printed = try? run("/bin/launchctl", ["print", service])
        let alreadyLoaded = printed != nil
        let loadedRunsManagedHelper = printed?.contains(helper.path) == true

        if alreadyLoaded && !plistChanged && loadedRunsManagedHelper {
            if needsRestart {
                // Same job definition, new binary: `-k` replaces the process
                // without unloading the job, which is gentler than bootout and
                // keeps the KeepAlive policy intact.
                try run("/bin/launchctl", ["kickstart", "-k", service])
            } else {
                // Same binary, same job definition: just make sure it is running.
                try run("/bin/launchctl", ["kickstart", service])
            }
            try? fileManager.removeItem(at: marker)
            return
        }

        if alreadyLoaded {
            // The loaded definition is stale: the plist on disk changed, or
            // the job runs a binary this app does not manage (an earlier
            // install at another path). `kickstart -k` would only restart the
            // process under that stale definition, so unload the job and load
            // the plist. The daemon owns live terminals either way: replacing
            // it means restarting it. RunAtLoad follows Always-on, so
            // bootstrap does not start the process on a laptop.
            _ = try? run("/bin/launchctl", ["bootout", service])
            try run("/bin/launchctl", ["bootstrap", domain, plist.path])
            try run("/bin/launchctl", ["kickstart", service])
            try? fileManager.removeItem(at: marker)
            return
        }

        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
        try run("/bin/launchctl", ["kickstart", service])
        try? fileManager.removeItem(at: marker)
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
        guard !hasNewerHelper else { return }
        guard let bundled = bundledHelper, let installed = installedHelper else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.path) else { return }
        if manager.fileExists(atPath: restartMarker(for: installed).path) {
            try? installAndStart()
            return
        }
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

    /// Prepare the whole executable beside its destination before replacing
    /// anything. A failed copy or rename leaves the installed helper intact
    /// and throws before the caller can restart its launch agent.
    @discardableResult
    static func replaceHelperIfNeeded(
        from bundled: URL,
        to helper: URL,
        fileManager: FileManager
    ) throws -> Bool {
        if fileManager.fileExists(atPath: helper.path),
           !helpersDiffer(bundled, helper, manager: fileManager)
        {
            return false
        }
        let staged = helper.deletingLastPathComponent()
            .appendingPathComponent(".tokenstat-hostd-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: bundled, to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // If the later plist write or launchctl fails, an identical binary
        // on the next attempt must still restart the old running process.
        try Data().write(to: restartMarker(for: helper), options: .atomic)
        guard rename(staged.path, helper.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func restartMarker(for helper: URL) -> URL {
        helper.appendingPathExtension("restart-required")
    }

    /// A newer installed release always wins, even when its size or date
    /// differs. Equal releases can still be different development builds.
    private static func helpersDiffer(_ a: URL, _ b: URL, manager: FileManager) -> Bool {
        let attributes: (URL) -> (Int, Date)? = { url in
            guard let values = try? manager.attributesOfItem(atPath: url.path),
                  let size = values[.size] as? Int,
                  let modified = values[.modificationDate] as? Date
            else { return nil }
            return (size, modified)
        }
        guard let left = attributes(a), let right = attributes(b) else { return true }
        let bundledVersion = version(of: a)
        let installedVersion = version(of: b)
        if isVersionNewer(installedVersion, than: bundledVersion) { return false }
        if left.0 != right.0 || left.1 != right.1 { return true }
        return isVersionNewer(bundledVersion, than: installedVersion)
    }

    /// All lifecycle entry points honor this, including launch-time refresh
    /// and quit. Guarding only Bridge.connect would still let an older app
    /// replace or stop the newer helper immediately afterwards.
    private static var hasNewerHelper: Bool { hasNewerHelper(patience: 5) }

    /// `patience` is how long the socket probe may wait for a host that is
    /// not answering. Callers that cannot wait use a short one and fall back
    /// to the installed-versus-bundled version compare below.
    private static func hasNewerHelper(patience: TimeInterval) -> Bool {
        let socketPath = identityDirectory.deletingLastPathComponent().appendingPathComponent("host.sock").path
        if let transport = SocketTransport.connecting(to: socketPath),
           let response = try? transport.call(method: "protocol", params: "{}", patience: patience),
           let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
           object["ok"] as? Bool == true,
           let result = object["result"] as? [String: Any],
           let raw = result["protocolVersion"] as? String,
           let actual = Int(raw), let expected = Int(InProcessTransport.protocolVersion), actual > expected {
            return true
        }
        guard let bundled = bundledHelper, let installed = installedHelper else { return false }
        return isVersionNewer(version(of: installed), than: version(of: bundled))
    }

    /// Last policy this process applied, so quit does not reread a stale file.
    private static var cachedAlwaysOn: Bool?

    /// Whether hostd should outlive the app.
    ///
    /// Missing `host.json`: keep the loaded plist's KeepAlive so a first
    /// launch does not flip a desktop install to off before hostd writes
    /// the hardware default. No plist either: off, the laptop-safe default.
    static func resolvedAlwaysOn() -> Bool {
        cachedAlwaysOn ?? storedAlwaysOn() ?? loadedPlistKeepAlive() ?? false
    }

    private static func loadedPlistKeepAlive() -> Bool? {
        guard let existing = NSDictionary(contentsOf: launchAgentPlistURL) else { return nil }
        return existing["KeepAlive"] as? Bool
    }

    static func storedAlwaysOn() -> Bool? {
        let url = identityDirectory.appendingPathComponent("host.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["alwaysOn"] as? Bool
        else { return nil }
        return value
    }

    private static var identityDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("ai.tokenstat.tokenstat/identity", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
    }

    /// Rewrite the launch agent so KeepAlive matches the switch.
    ///
    /// Changing KeepAlive requires unloading the job. That restarts hostd.
    /// Call this after `host.setPolicy`, while the app is open and will
    /// reconnect. Fails rather than caching a value the loaded job does
    /// not honour: KeepAlive still true plus hostd `exit(0)` is a restart loop.
    static func applyPolicy(alwaysOn: Bool) throws {
        let previous = cachedAlwaysOn
        cachedAlwaysOn = alwaysOn
        do {
            try installAndStart()
        } catch {
            cachedAlwaysOn = previous
            throw error
        }
    }

    /// How long the quit-time probe waits for the host.
    ///
    /// The ordinary patience is for a connection somebody is waiting on;
    /// quitting must not stand behind a wedged host for it. The version
    /// compare in `hasNewerHelper` still catches a newer installed helper
    /// when the socket says nothing.
    private static let quitProbePatience: TimeInterval = 0.5

    /// Stop hostd when Always-on is off. Leaves the job loaded so the next
    /// app launch can kickstart it. KeepAlive must already be false on the
    /// loaded job, or launchd will start it again.
    static func stopIfNotAlwaysOn() {
        guard !resolvedAlwaysOn(), !hasNewerHelper(patience: quitProbePatience) else { return }
        let service = "gui/\(getuid())/\(label)"
        _ = try? run("/bin/launchctl", ["kill", "SIGTERM", service])
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
    /// Numeric release parts, padded with zeros on the short side. A stable
    /// release follows its prereleases; build metadata does not change order.
    private static func isVersionNewer(_ a: String?, than b: String?) -> Bool {
        guard let a, let b else { return false }
        let left = versionNumbers(a)
        let right = versionNumbers(b)
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        let leftSuffix = prerelease(a)
        let rightSuffix = prerelease(b)
        guard let leftSuffix else { return rightSuffix != nil }
        guard let rightSuffix else { return false }
        return leftSuffix.compare(rightSuffix, options: [.literal, .numeric]) == .orderedDescending
    }

    private static func prerelease(_ raw: String) -> String? {
        let release = raw.split(separator: "+", maxSplits: 1).first ?? ""
        let parts = release.split(separator: "-", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    private static func versionNumbers(_ raw: String) -> [UInt64] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let withoutV = trimmed.first == "v" || trimmed.first == "V"
            ? String(trimmed.dropFirst())
            : trimmed
        let release = withoutV.split(separator: "+", maxSplits: 1).first.map(String.init) ?? withoutV
        let numeric = release.split(separator: "-", maxSplits: 1).first.map(String.init) ?? release
        return numeric.split(separator: ".").map { UInt64($0) ?? 0 }
    }

    /// Write the plist only when its contents actually changed, so a no-op
    /// install does not touch the file and re-trigger launchd bookkeeping.
    static func writePlistIfNeeded(_ contents: [String: Any], to plist: URL) throws -> Bool {
        let next = contents as NSDictionary
        if let existing = NSDictionary(contentsOf: plist), existing.isEqual(to: next) {
            return false
        }
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
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
