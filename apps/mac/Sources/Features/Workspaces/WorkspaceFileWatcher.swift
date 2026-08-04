// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import CoreServices
import Foundation


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
    /// Folders currently watched, so a re-watch with the same list is a no-op.
    private(set) var paths: [String] = []
    private weak var model: WorkspacesModel?
    private var stream: FSEventStreamRef?

    init(model: WorkspacesModel) {
        self.model = model
    }

    /// Watch `newPaths`, or keep the current stream when the list has not
    /// changed. Tearing a stream down on every refresh would be churn for
    /// nothing: the folder list is stable between edits.
    ///
    /// Folders that do not exist are skipped, FSEvents has nothing to watch.
    /// When such a folder comes back, `load` runs again and re-watches.
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
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
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

    /// FSEvents' own callback. The context pointer is this watcher, which the
    /// model owns, so the pointer stays valid for the stream's whole life.
    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
        // The stream's dispatch queue is the main queue, so this runs on the
        // main thread, which is where the actor lives.
        MainActor.assumeIsolated {
            watcher.model?.scheduleRefresh()
        }
    }
}
#endif
