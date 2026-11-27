// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Darwin
import Foundation

enum HostOwnerLock {
    private static var fd: Int32 = -1

    static func acquire() {
        acquire(at: lockPath)
    }

    static func acquire(at path: String) {
        guard fd < 0 else { return }
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )
        let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return }
        guard flock(opened, LOCK_SH) == 0 else {
            close(opened)
            return
        }
        fd = opened
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        pid.withCString { pointer in
            _ = ftruncate(fd, 0)
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    static func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    private static var lockPath: String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ai.tokenstat.tokenstat")
        return base?.appendingPathComponent("host-owner.lock").path
            ?? NSTemporaryDirectory() + "tokenstat-host-owner.lock"
    }
}
#endif
