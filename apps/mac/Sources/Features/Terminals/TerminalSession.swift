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

/// Terminal preferences, stored as user defaults and read by the terminal
/// strip and by the spawn path (which sends the colour choice to the daemon).
enum TerminalPreferences {
    private static let voiceOverKey = "terminal.accessibility.enabled"
    private static let noColorKey = "terminal.noColor.enabled"

    /// Expose the terminal's visible screen to VoiceOver as a text area.
    ///
    /// Defaults on when VoiceOver is already running the first time the key is
    /// read, so accessibility users are not left with a silent terminal until
    /// they find the Account toggle.
    static var exposesToVoiceOver: Bool {
        get {
            if UserDefaults.standard.object(forKey: voiceOverKey) == nil {
                return NSWorkspace.shared.isVoiceOverEnabled
            }
            return UserDefaults.standard.bool(forKey: voiceOverKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceOverKey) }
    }

    /// The user does not want colour: new terminals start with NO_COLOR=1.
    static var disablesColor: Bool {
        get { UserDefaults.standard.bool(forKey: noColorKey) }
        set { UserDefaults.standard.set(newValue, forKey: noColorKey) }
    }
}

/// One live terminal session: a host-owned pty and the SwiftTerm view that
/// renders it.
///
/// The process belongs to the host, not to this class, which is the point of
/// the host daemon. This side only reads output and sends keystrokes and
/// resize events, all over the same JSON bridge every other surface uses.
///
/// Output is read by offset and polled, never pushed. The SwiftTerm view is
/// created on attach (when a process exists), not on the click: building a
/// full emulator on the button action was main-thread work the user felt as
/// hitch, and an empty live terminal with a caret is what made a multi-second
/// agent boot read as "the app is broken" rather than "the agent is starting".
@MainActor
@Observable
final class TerminalSession: TerminalViewDelegate, Identifiable {
    /// Stable for the life of this object. SwiftUI `ForEach` and selection use
    /// this, and it must never change: swapping it from `pending-…` to the
    /// host's `pty-N` made every chip and the terminal stack tear down and
    /// rebuild on attach, which is the blink / disappear / reappear glitch.
    let id: String
    /// What the host knows this session as. `pending-…` until `attach`, then
    /// the real `pty-…` id used for every bridge call.
    private(set) var hostID: String
    nonisolated let workspaceID: String
    /// The command as launched, for a tab label.
    nonisolated let command: String
    /// Folder the session runs in, as the host reported it.
    nonisolated let cwd: String

    /// The archive source id when this command is a known harness.
    var harnessID: String? {
        switch URL(fileURLWithPath: command).lastPathComponent {
        case "claude": return "claude_code"
        case "codex": return "codex"
        case "opencode": return "opencode"
        case "grok": return "grok"
        case "copilot": return "copilot"
        case "muse": return "muse"
        case "pi": return "pi"
        default: return nil
        }
    }

    /// True while the process is running. Set from `pty.info` polls.
    var alive: Bool
    /// Set once the process has exited. `nil` while it still runs, which is
    /// not the same as having exited with status 0.
    var exitCode: Int?
    var rows: Int
    var cols: Int

    /// The size AppKit last reported, kept outside observation.
    ///
    /// `sizeChanged` arrives from inside an AppKit layout pass. Comparing
    /// against `rows`/`cols` there would be an observed *read* during layout,
    /// and writing them would be an observed write, which invalidates SwiftUI
    /// mid-pass. This shadow is what the delegate compares and writes; the
    /// observed pair catches up on the next turn.
    @ObservationIgnored private var reportedSize: (rows: Int, cols: Int)

    /// Why keystrokes are not reaching the process, when they are not. Set on
    /// a failed write so "I cannot type" is a visible, diagnosable state
    /// rather than a silently dropped `try?`.
    var transportError: String?

    /// The title the program asked for via OSC 0/2, when it set one.
    var title: String?
    /// The directory the program reported via OSC 7, when it reported one.
    var reportedCwd: String?

    /// Set when the host had to drop bytes because this reader fell behind its
    /// bounded buffer. The terminal cannot restore them, so the UI says so
    /// rather than pretending the output never existed.
    var droppedOutput = false

    /// True after the first host output has been fed into the emulator.
    ///
    /// Agent CLIs (Claude, Grok, …) take several seconds after `pty.spawn`
    /// returns before they paint. The pane uses this to show a starting state
    /// instead of an empty blinking terminal for that whole boot.
    private(set) var hasOutput = false

    /// The SwiftTerm view, created on first use after attach. Pending sessions
    /// have none: there is nothing to draw yet.
    @ObservationIgnored private var terminalView: TerminalView?

    /// The live emulator, if this session has one. Does not create it.
    var terminalViewIfLoaded: TerminalView? { terminalView }

    /// The emulator, created on first access. Only call after attach.
    var view: TerminalView {
        if let terminalView { return terminalView }
        let created = Self.makeTerminalView(delegate: self)
        terminalView = created
        return created
    }

    /// Where this reader is in the output stream.
    private var offset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var colorSchemeApplied: ColorScheme?

    /// True when this is the session the user is looking at.
    ///
    /// Only the visible session needs a keystroke-latency poll. A background
    /// session still has to drain the host's bounded buffer or it loses its
    /// earliest output, but nobody is waiting on those bytes to appear, so it
    /// drains at a rate that costs a fraction of the round trips. With several
    /// agents running at once that difference is most of the polling the app
    /// does.
    var isFocused = false {
        didSet {
            guard isFocused, isFocused != oldValue else { return }
            // Coming to the front should not wait out a background delay.
            wake()
        }
    }

    /// How long to wait before the next read. Held at the floor while output is
    /// flowing and backed off when it is not, because a fixed fast poll is a
    /// bridge round trip per session per frame forever, and idle sessions are
    /// the normal case.
    private var pollDelay = minPollDelay
    /// One display frame. Reading faster than the screen redraws buys nothing
    /// visible and costs a bridge round trip per session per read, which is
    /// what saturated the socket pool and made a launch click wait.
    private static let minPollDelay = 16
    /// The floor for a session nobody is looking at. Still far faster than the
    /// host's buffer fills, so no output is lost. Raised from 150 so several
    /// idle agents do not saturate the 16-connection socket pool.
    private static let backgroundPollDelay = 200
    private static let maxPollDelay = 400

    /// The fastest this session polls right now.
    private var pollFloor: Int {
        isFocused ? Self.minPollDelay : Self.backgroundPollDelay
    }
    /// Milliseconds of polling since the last liveness check.
    private var sinceInfo = 0

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
        id = UUID().uuidString
        hostID = info.id
        workspaceID = info.workspaceID ?? ""
        command = info.command
        cwd = info.cwd
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        reportedSize = (info.rows, info.cols)
        // Adopted from the host: the process already exists, so the emulator
        // is built now and polling starts immediately.
        _ = view
        start()
    }

    /// A session the user just asked for, before the host has spawned anything.
    ///
    /// Deliberately **no** TerminalView yet. The click only records intent and
    /// shows a starting pane; the emulator is built on `attach` when there is
    /// a process to talk to.
    init(pendingCommand command: String, workspace: WorkspaceFolder, rows: Int, cols: Int) {
        id = UUID().uuidString
        hostID = "pending-\(UUID().uuidString)"
        workspaceID = workspace.id
        self.command = command
        cwd = workspace.path
        alive = false
        exitCode = nil
        self.rows = rows
        self.cols = cols
        reportedSize = (rows, cols)
        isPending = true
    }

    /// True from the click until the host has spawned the process.
    var isPending = false

    /// True while the pane should show a starting state rather than the live
    /// emulator: still pending on the host, or the process is up but has not
    /// painted anything yet (agent CLIs spend seconds in that gap).
    var showsStartingState: Bool {
        (isPending || !hasOutput) && exitCode == nil
    }

    /// The host answered `pty.spawn`. Adopt the real host id, build the
    /// emulator, and start reading.
    func attach(info: PtySessionInfo) {
        // A session closed before the host answered must not come back: the
        // spawn still succeeded on the host, but nobody is watching it here.
        // Also ignore a second attach (list reconcile and spawn completion can
        // both try): the first one already owns the host id.
        guard isPending, !removed else { return }
        hostID = info.id
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        reportedSize = (info.rows, info.cols)
        isPending = false
        // Build the emulator now that a process exists. Before this there was
        // nothing to draw.
        _ = view
        start()
    }

    private static func makeTerminalView(delegate: TerminalViewDelegate) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.font = TerminalMetrics.font
        // Option-as-meta is how every terminal worth using behaves on a Mac,
        // and the agent CLIs are written assuming it.
        view.optionAsMetaKey = true
        // SwiftTerm defaults to 500 lines, which a build log passes in seconds.
        view.terminal.changeHistorySize(scrollbackLines)
        view.terminalDelegate = delegate
        return view
    }

    /// Set once the session is being torn down, so a late `attach` cannot
    /// restart polling on a session that is no longer in the model.
    private var removed = false

    /// Scrollback kept for the normal buffer. Enough to hold a long build or a
    /// test run, which is what anyone scrolling up is looking for.
    private static let scrollbackLines = 20_000

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
        // Pending sessions have no process behind them yet; attach() starts
        // polling once the host has answered.
        guard !isPending else { return }
        // Capture the host id once: it is stable after attach, and the writer
        // must not chase a changing value mid-stream.
        let bridgeID = hostID
        if writerTask == nil {
            writerTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.eventStream.stream {
                    switch event {
                    case let .write(bytes):
                        do {
                            try await Bridge.ptyWrite(id: bridgeID, bytes: bytes)
                            transportError = nil
                        } catch {
                            transportError = error.localizedDescription
                        }
                    case let .resize(rows, cols):
                        try? await Bridge.ptyResize(id: bridgeID, rows: rows, cols: cols)
                    }
                }
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.poll(id: bridgeID)
        }
    }

    /// Stop polling. Called when the session is closed.
    func stop() {
        removed = true
        pollTask?.cancel()
        pollTask = nil
        writerTask?.cancel()
        writerTask = nil
    }

    private func poll(id: String) async {
        while !Task.isCancelled {
            do {
                let chunk = try await Bridge.ptyRead(id: id, offset: offset)
                if chunk.dropped > 0 { droppedOutput = true }
                if !chunk.bytes.isEmpty {
                    feed(chunk.bytes)
                    offset = chunk.nextOffset
                    // Output is flowing, so stay at the floor: this is where
                    // typing latency comes from.
                    pollDelay = pollFloor
                } else {
                    pollDelay = min(max(pollDelay, pollFloor) * 2, Self.maxPollDelay)
                }
            } catch {
                // The session is gone on the host side; nothing more to read.
                break
            }

            // Liveness a few times a second, not on every poll: an info call is
            // a reaping opportunity, and the process needs to be reaped for its
            // exit code to be known.
            sinceInfo += pollDelay
            if sinceInfo >= 250 {
                sinceInfo = 0
                if let info = try? await Bridge.ptyInfo(id: id) {
                    // Guarded. These are observed, this runs several times a
                    // second per session, and the values almost never change:
                    // an unguarded write is a sidebar rebuild for nothing.
                    if rows != info.rows { rows = info.rows }
                    if cols != info.cols { cols = info.cols }
                    if alive != info.alive { alive = info.alive }
                    if let code = info.exitCode {
                        exitCode = code
                        // One last read in case output arrived right at exit.
                        if let final = try? await Bridge.ptyRead(id: id, offset: offset) {
                            if final.dropped > 0 { droppedOutput = true }
                            if !final.bytes.isEmpty {
                                offset = final.nextOffset
                                feed(final.bytes)
                            }
                        }
                        break
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(pollDelay))
        }
        pollTask = nil
    }

    /// Hand output to the terminal.
    ///
    /// `view.feed`, never `view.terminal.feed`. They look interchangeable and
    /// are not: the emulator's own `feed` updates the buffer and stops there,
    /// while the view's wraps it in `feedPrepare`/`feedFinish`, and it is
    /// `feedFinish` that asks for a repaint. Feeding the emulator directly
    /// leaves a terminal that takes input, runs the command, and shows nothing
    /// until an unrelated click or resize happens to invalidate the view.
    private func feed(_ bytes: Data) {
        if !hasOutput {
            hasOutput = true
        }
        view.feed(byteArray: ArraySlice(bytes))
        if TerminalPreferences.exposesToVoiceOver {
            publishAccessibilityValue()
        }
    }

    /// The terminal's visible screen as plain text, for VoiceOver.
    var visibleTerminalText: String {
        guard TerminalPreferences.exposesToVoiceOver else { return "" }
        let terminal = view.getTerminal()
        let dims = terminal.getDims()
        let top = terminal.getTopVisibleRow()
        let start = Position(col: 0, row: top)
        let end = Position(col: max(0, dims.cols), row: top + max(0, dims.rows))
        return terminal.getText(start: start, end: end)
    }

    private var lastAccessibilityValueAt: Date?

    /// Refresh the screen reader's copy of the screen, at most every quarter
    /// second: per-packet updates would rebuild the whole visible text for
    /// every byte.
    private func publishAccessibilityValue() {
        let now = Date()
        if let last = lastAccessibilityValueAt,
           now.timeIntervalSince(last) < 0.25
        {
            return
        }
        lastAccessibilityValueAt = now
        view.setAccessibilityValue(visibleTerminalText)
    }

    /// Drop back to the fast poll. Called when the user does something that
    /// should produce output right away, so the first keystroke after an idle
    /// stretch does not wait out a backed-off delay.
    func wake() {
        pollDelay = pollFloor
    }

    // MARK: - TerminalViewDelegate

    /// Keystrokes go back to the process. Bytes, not text: an escape sequence
    /// is a byte stream, which is why the transport base64s it. The write is
    /// queued, not sent here, so ordering survives the bridge.
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // AppKit delivers keystrokes on the main thread, where the actor lives.
        MainActor.assumeIsolated { wake() }
        eventStream.continuation.yield(.write(Array(data)))
    }

    /// The view settled on a new size, or the program asked for one. Tell the
    /// pty, which raises SIGWINCH so the shell redraws. Queued like a keystroke
    /// so a resize cannot interleave with input out of order.
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // AppKit calls this on the main thread, which is where the actor lives.
        let changed = MainActor.assumeIsolated {
            guard newCols != reportedSize.cols || newRows != reportedSize.rows else {
                return false
            }
            reportedSize = (newRows, newCols)
            // Out of the layout pass this arrived in. AppKit is inside
            // `setFrameSize` here, and an observed write from there makes
            // SwiftUI invalidate a hierarchy AppKit is still laying out.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if cols != newCols { cols = newCols }
                if rows != newRows { rows = newRows }
            }
            return true
        }
        // A resize the pty already has is not a no-op: it still raises SIGWINCH,
        // and a shell reprints its prompt and a full screen program repaints
        // everything. The first layout of a session spawned at the right size
        // reports exactly the size it already is, so this is the common case.
        guard changed else { return }
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

    nonisolated func scrolled(source: TerminalView, position: Double) {
        Task { @MainActor [weak self] in
            self?.lastAccessibilityValueAt = nil
            self?.publishAccessibilityValue()
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 clipboard write from the program inside the terminal. Denied:
    /// a remote process must not write this Mac's clipboard uninvited.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
}
#endif
