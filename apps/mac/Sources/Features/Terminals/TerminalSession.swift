// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftTerm
import SwiftUI

/// One live terminal session: a host-owned pty and the SwiftTerm view that
/// renders it.
///
/// The process belongs to the host, not to this class, which is the point of
/// the host daemon. This side only reads output and sends keystrokes and
/// resize events, all over the same JSON bridge every other surface uses.
///
/// Output is read by offset and polled, never pushed, so a session keeps up
/// even while its tab is hidden and a view that appears later resumes exactly
/// where the stream is rather than missing what ran before it. The SwiftTerm
/// view is created once and reused, so the emulator's scrollback survives tab
/// switches and leaving the screen.
@MainActor
@Observable
final class TerminalSession: TerminalViewDelegate, Identifiable {
    nonisolated let id: String
    nonisolated let workspaceID: String
    /// The command as launched, for a tab label.
    nonisolated let command: String
    /// Folder the session runs in, as the host reported it.
    nonisolated let cwd: String

    /// True while the process is running. Set from `pty.info` polls.
    var alive: Bool
    /// Set once the process has exited. `nil` while it still runs, which is
    /// not the same as having exited with status 0.
    var exitCode: Int?
    var rows: Int
    var cols: Int

    /// The title the program asked for via OSC 0/2, when it set one.
    var title: String?
    /// The directory the program reported via OSC 7, when it reported one.
    var reportedCwd: String?

    /// Set when the host had to drop bytes because this reader fell behind its
    /// bounded buffer. The terminal cannot restore them, so the UI says so
    /// rather than pretending the output never existed.
    var droppedOutput = false

    /// The SwiftTerm view. Created on first display and kept, so the terminal
    /// emulator's state is never lost to a tab switch.
    private(set) var view: TerminalView?

    /// Where this reader is in the output stream. Always read from here, fed
    /// only when a view exists, so a view that appears later resumes exactly
    /// where the output is rather than missing what ran before it.
    private var offset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var pollsSinceInfo = 0
    private var colorSchemeApplied: ColorScheme?

    /// Keystrokes and resizes land here in the order the UI produced them,
    /// then a single writer task sends them to the pty one at a time. Without
    /// this, two rapid writes could race through the bridge and arrive at the
    /// process in the wrong order, which is exactly how a terminal starts
    /// swapping characters.
    private enum PtyEvent {
        case write([UInt8])
        case resize(rows: Int, cols: Int)
    }

    nonisolated private let eventStream = AsyncStream<PtyEvent>.makeStream()

    init(info: PtySessionInfo) {
        id = info.id
        workspaceID = info.workspaceID ?? ""
        command = info.command
        cwd = info.cwd
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
    }

    /// The view to place in the hierarchy. Creates it on first call, wires it
    /// to this session, and returns the same instance afterwards so the
    /// emulator's scrollback is never lost to a tab switch.
    func makeView() -> TerminalView {
        if let view { return view }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Option-as-meta is how every terminal worth using behaves on a Mac,
        // and the agent CLIs are written assuming it.
        view.optionAsMetaKey = true
        self.view = view
        start()
        return view
    }

    /// Re-theme the view when the system appearance changed.
    func applyColors(scheme: ColorScheme, to view: TerminalView) {
        guard scheme != colorSchemeApplied else { return }
        colorSchemeApplied = scheme
        // Same two surfaces as the rest of the app, so the terminal reads as
        // part of the pane rather than as a white block in a dark window.
        let background: UInt32 = scheme == .dark ? 0x0A0A0B : 0xF7F7F8
        let foreground: UInt32 = scheme == .dark ? 0xDCDCE0 : 0x1C1C1F
        view.nativeBackgroundColor = Self.nsColor(background)
        view.nativeForegroundColor = Self.nsColor(foreground)
        view.caretColor = NSColor(Theme.accent)
        view.setNeedsDisplay(view.bounds)
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Begin polling and the writer. Safe to call more than once.
    func start() {
        if writerTask == nil {
            writerTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.eventStream.stream {
                    switch event {
                    case let .write(bytes):
                        try? await Bridge.ptyWrite(id: self.id, bytes: bytes)
                    case let .resize(rows, cols):
                        try? await Bridge.ptyResize(id: self.id, rows: rows, cols: cols)
                    }
                }
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.poll()
        }
    }

    /// Stop polling. Called when the session is closed.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        writerTask?.cancel()
        writerTask = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let chunk = try await Bridge.ptyRead(id: id, offset: offset)
                if chunk.dropped > 0 { droppedOutput = true }
                if let view, !chunk.data.isEmpty, let bytes = Data(base64Encoded: chunk.data) {
                    view.terminal.feed(byteArray: [UInt8](bytes))
                    offset = chunk.nextOffset
                }
                // With no view yet the offset stays where it is, so the bytes
                // remain in the host buffer until there is something to render
                // them. A view that appears later resumes from this offset
                // rather than missing everything that ran before it.
            } catch {
                // The session is gone on the host side; nothing more to read.
                break
            }

            // Liveness a few times a second, not on every poll: an info call is
            // a reaping opportunity, and the process needs to be reaped for its
            // exit code to be known.
            pollsSinceInfo += 1
            if pollsSinceInfo >= 4 {
                pollsSinceInfo = 0
                if let info = try? await Bridge.ptyInfo(id: id) {
                    rows = info.rows
                    cols = info.cols
                    alive = info.alive
                    if let code = info.exitCode {
                        exitCode = code
                        // One last read in case output arrived right at exit.
                        if let final = try? await Bridge.ptyRead(id: id, offset: offset) {
                            if final.dropped > 0 { droppedOutput = true }
                            if let bytes = Data(base64Encoded: final.data), !bytes.isEmpty {
                                offset = final.nextOffset
                                view?.terminal.feed(byteArray: [UInt8](bytes))
                            }
                        }
                        break
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(16))
        }
        pollTask = nil
    }

    // MARK: - TerminalViewDelegate

    /// Keystrokes go back to the process. Bytes, not text: an escape sequence
    /// is a byte stream, which is why the transport base64s it. The write is
    /// queued, not sent here, so ordering survives the bridge.
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        eventStream.continuation.yield(.write(Array(data)))
    }

    /// The view settled on a new size, or the program asked for one. Tell the
    /// pty, which raises SIGWINCH so the shell redraws. Queued like a keystroke
    /// so a resize cannot interleave with input out of order.
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // AppKit calls this on the main thread, which is where the actor lives.
        MainActor.assumeIsolated {
            cols = newCols
            rows = newRows
        }
        eventStream.continuation.yield(.resize(rows: newRows, cols: newCols))
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            self.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            reportedCwd = directory
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 clipboard write from the program inside the terminal. Denied:
    /// a remote process must not write this Mac's clipboard uninvited.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
}
#endif
