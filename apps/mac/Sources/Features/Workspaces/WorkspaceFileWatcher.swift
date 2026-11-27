// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import CoreServices
import Foundation
import OSLog

#if DEBUG
private let watchLog = Logger(subsystem: "ai.tokenstat.tokenstat", category: "Performance")
#endif


/// Watches workspace folders so git state can refresh itself.
///
/// The alternative is a poll timer, which either misses the instant a save
/// lands or runs git on a schedule nobody asked for. FSEvents reports when
/// files changed, which is exactly the trigger a working-tree pane wants.
///
/// One stream over every registered folder. It only reports that something
/// changed, never what, because the model re-reads all of git on any event
/// anyway. The stream runs on the main queue so the callback can hand straight
/// to the `@MainActor` model. Deciding how often to refresh is the model's
/// debounce, not this class's job.
final class WorkspaceFileWatcher {
    private(set) var paths: [String] = []
    private weak var model: WorkspacesModel?
    private var stream: FSEventStreamRef?

    init(model: WorkspacesModel) {
        self.model = model
    }

    func watch(_ newPaths: [String]) {
        let existing = newPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != paths else { return }
        stop()
        paths = existing
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            paths = []
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray)
            as? [String] ?? []
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENSTAT_LOG_ALL_CALLS"] != nil {
            watchLog.debug("fs events \(paths.joined(separator: " | "), privacy: .public)")
        }
        #endif
        MainActor.assumeIsolated {
            switch WorkspaceChangeFilter.classify(paths, among: watcher.paths) {
            case .none:
                break
            case let .roots(roots):
                watcher.model?.scheduleRefresh(roots: roots)
            case .unknown:
                watcher.model?.scheduleRefresh()
            }
        }
    }
}
#endif
