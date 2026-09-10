// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HostAgentInstaller.swift.
import Foundation

// These tests call only the installer's filesystem operations in a private
// temporary directory. They never install, start or stop a real launch agent.
struct SocketTransport {
    static func connecting(to _: String) -> SocketTransport? { nil }
    func call(method: String, params: String, patience: TimeInterval) throws -> String { "" }
}
enum InProcessTransport { static let protocolVersion = "14" }

private final class RejectPermissions: FileManager, @unchecked Sendable {
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@main struct HostAgentInstallerTests {
    private static func expect(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
        assert(value, file: file, line: line)
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tokenstat-helper-test-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let installed = root.appendingPathComponent("installed")
        let old = try helper("1.0.0", at: installed)
        let next = try helper("1.0.1", at: bundled)
        let marker = HostAgentInstaller.restartMarker(for: installed)

        func remainsOld() throws {
            expect(try Data(contentsOf: installed) == old)
            assert(!manager.fileExists(atPath: marker.path))
            expect(try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".tokenstat-hostd-") }.isEmpty)
        }
        do {
            _ = try HostAgentInstaller.replaceHelperIfNeeded(from: root.appendingPathComponent("missing"), to: installed, fileManager: manager)
            assertionFailure("A failed copy was reported as an install")
        } catch {}
        try remainsOld()
        do {
            _ = try HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: installed, fileManager: RejectPermissions())
            assertionFailure("A non-executable staged copy was installed")
        } catch {}
        try remainsOld()

        // Failure to record the pending restart must also leave the old
        // executable intact, so a retry never loses the need to restart it.
        try manager.createDirectory(at: marker, withIntermediateDirectories: false)
        do {
            _ = try HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: installed, fileManager: manager)
            assertionFailure("An unrecorded replacement was installed")
        } catch {}
        expect(try Data(contentsOf: installed) == old)
        try manager.removeItem(at: marker)

        expect(try HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: installed, fileManager: manager))
        expect(try Data(contentsOf: installed) == next)
        let permissions = try manager.attributesOfItem(atPath: installed.path)[.posixPermissions] as? NSNumber
        assert(permissions?.intValue == 0o755)
        assert(manager.fileExists(atPath: marker.path))
        // Simulate a subsequent plist/restart failure: the copy is now equal,
        // but the durable restart marker survives the next copy check.
        expect(try !HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: installed, fileManager: manager))
        assert(manager.fileExists(atPath: marker.path))

        // A rename failure cannot remove the previous destination contents.
        let destination = root.appendingPathComponent("directory")
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep")
        try old.write(to: sentinel)
        do {
            _ = try HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: destination, fileManager: manager)
            assertionFailure("A failed rename was reported as an install")
        } catch {}
        expect(try Data(contentsOf: sentinel) == old)
        expect(try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".tokenstat-hostd-") }.isEmpty)

        for (older, newer) in [("1.0.1", "1.2.0"), ("1.0.1-rc.2", "1.0.1"), ("1.0.1-rc.2", "1.0.1-rc.10"), ("1.0.1+build.20", "1.0.2+build.1")] {
            _ = try helper(older, at: bundled)
            let newerBytes = try helper(newer, at: installed, padding: "# different size and date\n")
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: installed.path)
            expect(try !HostAgentInstaller.replaceHelperIfNeeded(from: bundled, to: installed, fileManager: manager))
            expect(try Data(contentsOf: installed) == newerBytes)
        }

        let plist = root.appendingPathComponent("helper.plist")
        let values: [String: Any] = ["Label": "fixture", "KeepAlive": false]
        expect(try HostAgentInstaller.writePlistIfNeeded(values, to: plist))
        let saved = try Data(contentsOf: plist)
        expect(try !HostAgentInstaller.writePlistIfNeeded(values, to: plist))
        do {
            _ = try HostAgentInstaller.writePlistIfNeeded(["invalid": NSObject()], to: plist)
            assertionFailure("A failed plist write was accepted")
        } catch {}
        expect(try Data(contentsOf: plist) == saved)
        print("Host helper: failed copies/permissions/markers/renames preserve existing files; replacement, retry marker, newer releases and plist failures passed")
    }

    @discardableResult private static func helper(_ version: String, at url: URL, padding: String = "") throws -> Data {
        let data = Data(("#!/bin/sh\nprintf 'tokenstat-hostd \(version)\\n'\n" + padding).utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return data
    }
}
