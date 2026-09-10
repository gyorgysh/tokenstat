// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Darwin

/// A live store may hold unsaved references. Deletion is allowed only when this
/// process is the sole participant, then performs its live-reference check while
/// a short gate prevents another process from joining. No lock crosses an await.
enum OriginalFileCoordination {
    enum Failure: LocalizedError {
        case unavailable, anotherInstance, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "Original-file access could not be checked. The file has been kept."
            case .busy: "This original file is being used. Try again when the current operation finishes."
            case .anotherInstance: "Close the other running instance of tokenstat before removing original files."
            }
        }
    }
    /// Retry a failed registration when storage becomes available again, while
    /// retaining successful participation for the entire store lifetime.
    final class Registration: @unchecked Sendable {
        private let directory: URL
        private var participant: Participant?
        init(directory: URL) { self.directory = directory }
        func get() throws -> Participant {
            mutex.lock(); defer { mutex.unlock() }
            if let participant { return participant }
            let joined = try join(directory: directory)
            participant = joined
            return joined
        }
    }

    final class Participant: @unchecked Sendable {
        fileprivate let root: URL
        fileprivate let file: URL
        fileprivate var uses: [String: Int] = [:]
        private let descriptor: Int32
        fileprivate init(root: URL, file: URL, descriptor: Int32) {
            self.root = root; self.file = file; self.descriptor = descriptor
        }
        deinit { Darwin.close(descriptor) }
    }
    final class Activity: @unchecked Sendable {
        private let participant: Participant
        private let key: String
        fileprivate init(_ participant: Participant, key: String) {
            self.participant = participant; self.key = key
        }
        deinit {
            mutex.lock(); defer { mutex.unlock() }
            let remaining = (participant.uses[key] ?? 1) - 1
            participant.uses[key] = remaining > 0 ? remaining : nil
        }
    }

    static func use(_ participant: Participant, file: URL) -> Activity {
        mutex.lock(); defer { mutex.unlock() }
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        participant.uses[key, default: 0] += 1
        return Activity(participant, key: key)
    }

    private final class WeakParticipant {
        weak var value: Participant?
        init(_ value: Participant) { self.value = value }
    }
    // POSIX record locks are process-scoped, so serialize handles within this
    // process too. Nested work on an already-held gate must not open/close a
    // second descriptor, which would release the outer record lock.
    private static let mutex = NSRecursiveLock()
    private static var participants: [String: WeakParticipant] = [:]
    private static var gates: Set<String> = []

    static func join(directory: URL) throws -> Participant {
        mutex.lock(); defer { mutex.unlock() }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(".original-file-owners", isDirectory: true)
        if let held = participants[root.path]?.value { return held }
        return try gated(root, wait: true) {
            let file = root.appendingPathComponent(UUID().uuidString + ".lease")
            let descriptor = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw Failure.unavailable }
            guard lock(descriptor, wait: false) else { Darwin.close(descriptor); throw Failure.unavailable }
            let participant = Participant(root: root, file: file, descriptor: descriptor)
            participants = participants.filter { $0.value.value != nil }
            participants[root.path] = WeakParticipant(participant)
            return participant
        }
    }

    static func whileSoleParticipant<T>(_ participant: Participant, removing file: URL, _ work: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        return try gated(participant.root, wait: false) {
            let key = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard participant.uses[key] == nil else { throw Failure.busy }
            let files = try FileManager.default.contentsOfDirectory(at: participant.root,
                includingPropertiesForKeys: nil, options: [])
            for file in files where file.pathExtension == "lease" && file.path != participant.file.path {
                let descriptor = Darwin.open(file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    if errno == ENOENT { continue }
                    throw Failure.unavailable
                }
                guard lock(descriptor, wait: false) else {
                    Darwin.close(descriptor)
                    throw Failure.anotherInstance
                }
                // No participant can join while this gate is held. Dead-process
                // lease files can be pruned without replacing a live lock inode.
                defer { Darwin.close(descriptor) }
                try FileManager.default.removeItem(at: file)
            }
            return try work()
        }
    }

    private static func gated<T>(_ root: URL, wait: Bool, _ work: () throws -> T) throws -> T {
        if gates.contains(root.path) { return try work() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(root.appendingPathComponent("gate.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        guard lock(descriptor, wait: wait) else { throw Failure.unavailable }
        gates.insert(root.path)
        defer { gates.remove(root.path) }
        return try work()
    }

    private static func lock(_ descriptor: Int32, wait: Bool) -> Bool {
        var region = flock()
        region.l_type = Int16(F_WRLCK)
        region.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, wait ? F_SETLKW : F_SETLK, &region) == -1 {
            if errno != EINTR { return false }
        }
        return true
    }
}
