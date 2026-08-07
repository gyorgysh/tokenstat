// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation

/// Replacing this application with a newer one.
///
/// # Why the verification is not optional
///
/// This code downloads something and then runs it as the user. That is exactly
/// the shape of a remote code execution bug, and the only thing standing
/// between the two is what it checks before it moves anything into place. Three
/// checks, none of which replaces another:
///
/// 1. The daemon verified the download against the release's `SHA256SUMS`. That
///    proves the bytes are the ones the release published.
/// 2. `codesign` here proves the bundle inside is intact and signed.
/// 3. `spctl` proves Gatekeeper would let the user open it, which is the check
///    that means a Developer ID Apple has not revoked.
///
/// A checksum alone would trust whoever wrote the release. A signature alone
/// would trust a bundle that had been tampered with after signing. If any check
/// fails, nothing is moved and the caller falls back to sending the user to the
/// download page.
///
/// # Why it replaces rather than asks
///
/// macOS lets a running bundle be replaced: the process holds its own open file
/// handles and carries on. So the new version is put in place while the app is
/// still running, and the interface then offers a relaunch. Nothing restarts
/// under somebody mid-sentence.
enum AppInstaller {
    enum Failure: LocalizedError {
        case notMounted(String)
        case noAppInImage
        case unsigned(String)
        case rejectedByGatekeeper(String)
        case authorizationFailed(String)
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .notMounted(let why): return "The download could not be opened: \(why)"
            case .noAppInImage: return "The download did not contain tokenstat."
            case .unsigned(let why): return "The download is not correctly signed: \(why)"
            case .rejectedByGatekeeper(let why): return "macOS refused the download: \(why)"
            case .authorizationFailed(let why):
                return "The update needs your Mac password to replace the app: \(why)"
            case .replaceFailed(let why): return "The update could not be put in place: \(why)"
            }
        }
    }

    /// Install the disk image at `imagePath` over the running application.
    ///
    /// Off the main actor: it mounts a disk image and copies tens of megabytes,
    /// and doing that on the main thread would freeze the window for the whole
    /// of it.
    static func install(imagePath: String) throws {
        let mountPoint = try attach(imagePath)
        defer { detach(mountPoint) }

        let mounted = mountPoint.appendingPathComponent("Tokenstat.app")
        guard FileManager.default.fileExists(atPath: mounted.path) else {
            throw Failure.noAppInImage
        }

        try verify(mounted)
        try replaceRunningBundle(with: mounted)
        // The Dock and LaunchServices cache a bundle's icon and identity the
        // first time they see it. Replacing the bundle in place leaves that
        // cache pointing at the old entry, which is how an update sometimes
        // ends with a stale or duplicate dock icon. Re-register the new
        // bundle and point this still-running instance's dock tile at the new
        // icon, so the update is visible before the relaunch, not only after.
        let current = Bundle.main.bundleURL
        refreshLaunchServices(bundle: current)
        DispatchQueue.main.async {
            updateDockIcon(to: current)
        }
    }

    // MARK: - The image

    private static func attach(_ imagePath: String) throws -> URL {
        // -nobrowse keeps it out of the Finder sidebar: this is machinery, not
        // something the user opened. -readonly because nothing writes to it.
        let out = run("/usr/bin/hdiutil", [
            "attach", imagePath,
            "-nobrowse", "-readonly", "-noverify",
            "-mountrandom", NSTemporaryDirectory(),
        ])
        guard out.status == 0 else { throw Failure.notMounted(out.errors) }

        // The last tab-separated field of the last line is the mount point.
        let mount = out.output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.components(separatedBy: "\t")
                guard let last = fields.last?.trimmingCharacters(in: .whitespaces),
                      last.hasPrefix("/") else { return nil }
                return last
            }
            .last
        guard let mount else { throw Failure.notMounted("no mount point in hdiutil's output") }
        return URL(fileURLWithPath: mount)
    }

    private static func detach(_ mountPoint: URL) {
        // Best effort. A mount left behind is untidy; failing the update over
        // it would be worse, and the reboot everybody eventually does clears it.
        _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    // MARK: - The checks

    private static func verify(_ app: URL) throws {
        let signed = run("/usr/bin/codesign", [
            "--verify", "--deep", "--strict", "--verbose=2", app.path,
        ])
        guard signed.status == 0 else { throw Failure.unsigned(firstLine(signed.errors)) }

        // The identity has to be the one that signs this app, not merely *an*
        // identity. Without this a validly signed, validly notarized
        // application from anybody at all would pass, which is not a check, it
        // is a formality.
        let authority = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard authority.errors.contains("TeamIdentifier=\(expectedTeam)"),
              authority.errors.contains("Authority=Developer ID Application:")
        else {
            throw Failure.unsigned("it was signed by somebody else")
        }

        let gate = run("/usr/sbin/spctl", [
            "--assess", "--type", "execute", "--verbose=2", app.path,
        ])
        guard gate.status == 0 else {
            throw Failure.rejectedByGatekeeper(firstLine(gate.errors))
        }
    }

    /// The team the shipped builds are signed by.
    ///
    /// The team identifier rather than the certificate's display name: the name
    /// carries a non-ASCII character and could be re-issued differently, while
    /// this string is assigned by Apple and stays put across certificate
    /// renewals. Verifiable by hand with the same command this runs:
    ///
    ///     codesign -dv --verbose=4 /Applications/Tokenstat.app
    ///
    /// Paired with a check that the authority is a Developer ID at all, so a
    /// self-signed certificate that merely claims this team cannot pass.
    private static let expectedTeam = "8SY98BT8RV"

    // MARK: - Putting it in place

    private static func replaceRunningBundle(with fresh: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) {
            try replaceUnprivileged(fresh, at: current, in: parent)
            return
        }
        // The ordinary failure: the app lives in /Applications and a normal
        // user cannot write there. Replacing it is exactly what the user
        // wants, so ask for their password and do the copy with admin rights
        // rather than giving up and sending them to a download page.
        try replaceAuthenticated(fresh, at: current, in: parent)
    }

    /// Swap the bundle in place when the folder is writable by this user.
    private static func replaceUnprivileged(
        _ fresh: URL,
        at current: URL,
        in parent: URL
    ) throws {
        let fm = FileManager.default
        let staged = parent.appendingPathComponent("Tokenstat.app.incoming")
        try? fm.removeItem(at: staged)

        do {
            // Copied beside the old one first, so a copy that fails part way
            // through has not touched the application the user is running.
            // Only when a whole bundle is on the same volume is anything
            // swapped, and that swap is one rename.
            try fm.copyItem(at: fresh, to: staged)
            _ = try fm.replaceItemAt(current, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure.replaceFailed(error.localizedDescription)
        }
    }

    /// Replace the bundle with administrator rights, asking for the password.
    ///
    /// Runs the copy through `osascript`'s `do shell script ... with
    /// administrator privileges`, which puts up the standard macOS password
    /// prompt. The bundle being copied was already checksum-verified and
    /// code-signed before this point, so the only new trust being granted is
    /// "let this user write to the folder the app lives in".
    ///
    /// Same staging shape as the unprivileged path: the new bundle is copied
    /// to a sibling first, and only once it is whole on disk is the old one
    /// removed and the new one moved over it. A failure part way through
    /// leaves the running application untouched.
    private static func replaceAuthenticated(
        _ fresh: URL,
        at current: URL,
        in parent: URL
    ) throws {
        let staged = parent.appendingPathComponent("Tokenstat.app.incoming")
        let command = [
            "/bin/rm -rf \(shellQuote(staged.path))",
            "/usr/bin/ditto \(shellQuote(fresh.path)) \(shellQuote(staged.path))",
            "/bin/rm -rf \(shellQuote(current.path))",
            "/bin/mv \(shellQuote(staged.path)) \(shellQuote(current.path))",
            "/usr/bin/xattr -dr com.apple.quarantine \(shellQuote(current.path))",
        ].joined(separator: " && ")

        // The shell command goes inside an AppleScript string, so double
        // quotes have to be escaped for AppleScript before the shell ever
        // sees them.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let out = run("/usr/bin/osascript", ["-e", script])
        guard out.status == 0 else {
            let why = firstLine(out.errors.isEmpty ? out.output : out.errors)
            throw Failure.authorizationFailed(why)
        }
    }

    /// Quote a path for a `/bin/sh` command line.
    ///
    /// App paths can contain spaces and the mount point is under a temp
    /// directory, so neither side can be trusted bare. Single-quoting handles
    /// everything except a quote inside the path, which is escaped the shell
    /// way.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Relaunching

    /// Start the freshly installed copy and quit this one.
    ///
    /// `open` rather than re-executing ourselves: this process is the old
    /// bundle's image, and launching through the Finder's own path is what
    /// makes the new one come up as a normal application with its own
    /// activation, rather than a child of a process that is about to die.
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundle.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Re-register the bundle with LaunchServices.
    ///
    /// `lsregister -f` forces the icon and metadata caches to re-read the
    /// bundle, which is what stops an in-place update from leaving the old
    /// icon in the Dock or Launchpad.
    private static func refreshLaunchServices(bundle: URL) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = ["-f", bundle.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // The cache refresh is a nicety; a failed one must not fail the
            // update that already succeeded.
        }
    }

    /// Point this running instance's dock tile at the replaced bundle's icon.
    ///
    /// The process keeps its launch-time tile after its bundle is swapped
    /// underneath it; loading the icon file from the new bundle and handing it
    /// to AppKit updates the tile immediately.
    @MainActor
    private static func updateDockIcon(to bundle: URL) {
        let icon = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if let image = NSImage(contentsOf: icon) {
            NSApp.applicationIconImage = image
        }
    }

    // MARK: - Running a tool

    private struct Output {
        var status: Int32
        var output: String
        var errors: String
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Output {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            return Output(status: -1, output: "", errors: error.localizedDescription)
        }
        // Read before waiting: a tool that fills the pipe buffer blocks forever
        // if nobody is draining it, and codesign is chatty.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Output(
            status: task.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errors: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? "no reason given"
    }
}
#endif
