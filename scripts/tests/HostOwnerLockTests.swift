// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HostOwnerLock.swift.
import Darwin
import Foundation

@main struct HostOwnerLockTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("host-owner.lock").path
        defer {
            HostOwnerLock.release()
            try? FileManager.default.removeItem(at: directory)
        }
        HostOwnerLock.acquire(at: path)
        let probe = open(path, O_RDWR | O_CLOEXEC)
        assert(probe >= 0)
        defer { close(probe) }
        assert(flock(probe, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)

        // Verify the actual lifetime-lock descriptor cannot escape into an
        // exec'd child, independently of Foundation Process's own fd cleanup.
        var expected = stat()
        assert(fstat(probe, &expected) == 0)
        var owners: [Int32] = []
        for descriptor in 0..<getdtablesize() where descriptor != probe {
            var actual = stat()
            if fstat(descriptor, &actual) == 0,
               actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino {
                owners.append(descriptor)
                assert(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            }
        }
        assert(owners.count == 1)
        HostOwnerLock.acquire(at: path)
        HostOwnerLock.release()
        assert(flock(probe, LOCK_EX | LOCK_NB) == 0)
        assert(flock(probe, LOCK_UN) == 0)
        HostOwnerLock.release()
        print("Host owner lock: exclusive probe, close-on-exec and idempotent acquire/release passed")
    }
}
