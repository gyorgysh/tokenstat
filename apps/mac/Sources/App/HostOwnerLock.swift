// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Darwin
import Foundation

/// Shared lock the host helper watches when Always-on host is off.
///
/// Each Tokenstat process holds a shared flock on `host-owner.lock`. hostd
/// probes with a non-blocking exclusive lock: if that succeeds, no app is
/// open and the helper may exit. A clean quit also kills the job. This lock
/// covers force-quit and crash, where `applicationWillTerminate` never runs.
enum HostOwnerLock {
    private static var fd: Int32 = -1

    static func acquire() {
        guard fd < 0 else { return }
        let path = lockPath
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )
        let opened = open(path, O_RDWR | O_CREAT, 0o600)
        guard opened >= 0 else { return }
        fd = opened
        // Shared: two Tokenstat processes (debug and the installed app) must
        // both count as an owner. hostd's exclusive probe fails while either
        // holds this.
        _ = flock(fd, LOCK_SH)
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        _ = pid.withCString { pointer in
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
