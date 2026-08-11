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

/// What a session is doing right now, for the sidebar and session rows.
///
/// Derived at transition points rather than recomputed in the view, so a row
/// only redraws when the state actually changes.
enum SessionState: Equatable {
    /// No process, or the session is gone.
    case none
    /// A spawn is in flight but the host has not answered yet.
    case starting
    /// The process is alive and produced output recently.
    case working
    /// The process is alive but has been quiet for a while.
    case idle
    /// The process has exited.
    case stopped

    var label: String {
        switch self {
        case .none: return "None"
        case .starting: return "Starting"
        case .working: return "Working"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        }
    }
}

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
    ///
    /// Cached after the first read. This is checked on the output path, which
    /// for a printing process runs thousands of times a second, and a defaults
    /// lookup per line of a build log is a cost nobody asked for. The toggle
    /// writes through the cache, so the only way to miss a change is to edit
    /// the domain from outside the app.
    static var exposesToVoiceOver: Bool {
        get {
            if let cached = voiceOverCache { return cached }
            let value: Bool
            if UserDefaults.standard.object(forKey: voiceOverKey) == nil {
                value = NSWorkspace.shared.isVoiceOverEnabled
            } else {
                value = UserDefaults.standard.bool(forKey: voiceOverKey)
            }
            voiceOverCache = value
            return value
        }
        set {
            voiceOverCache = newValue
            UserDefaults.standard.set(newValue, forKey: voiceOverKey)
        }
    }

    private nonisolated(unsafe) static var voiceOverCache: Bool?

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

    /// When the process last produced output. `nil` until the first output,
    /// or when the host predates the activity field, so "unknown" is not the
    /// same as "idle".
    ///
    /// **Not observed.** This is written on every packet the process emits,
    /// which for a busy agent is hundreds of times a second, and an observed
    /// write there invalidates every view that has ever read it: the sidebar
    /// was being rebuilt at the rate the terminal was printing. The one view
    /// that reads it, the idle clock, is rebuilt when `state` changes, which
    /// is exactly when the value it wants has settled.
    @ObservationIgnored private(set) var lastOutputAt: Date?

    /// What the session is doing right now. Updated at transition points, so
    /// a sidebar row only redraws when the state changes.
    private(set) var state: SessionState = .none

    /// Smoothed CPU of the session's process subtree, percent of one core,
    /// as measured by the host. `nil` until the sampler has a reading.
    private(set) var cpuPercent: Double?

    /// Resident memory of the session's process subtree, in megabytes.
    private(set) var memoryMb: Double?

    /// True once the host has answered with a real verdict.
    ///
    /// While this is false the app falls back to its own "did bytes arrive
    /// recently" guess. That guess is wrong in both directions, which is why
    /// it is only ever a stand-in for the first second of a session's life
    /// and for a daemon too old to have the detector: an agent redrawing a
    /// spinner produces bytes forever and looks eternally busy, and one
    /// waiting on a model produces none and looks idle mid-thought.
    private var hostReportedActivity = false

    /// Flips a working session to idle after silence. Cancelled whenever
    /// output resumes, so transitions cannot pile up.
    private var idleCheckTask: Task<Void, Never>?

    /// Seconds of silence after which a live session reads as idle.
    private static let idleThreshold: TimeInterval = 20

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
    /// When the last loop pass ran, so elapsed time can be measured rather than
    /// assumed from the delay that was scheduled.
    private var lastLoopAt = Date()
    /// How long the host may hold a read open for the focused session.
    ///
    /// A quarter second: long enough that an idle terminal costs four round
    /// trips a second instead of sixty, short enough that a connection is never
    /// parked for a noticeable time and a session that loses focus stops
    /// holding one almost at once.
    private static let readHold = 250

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
        applyState(
            alive: info.alive,
            exitCode: info.exitCode,
            lastActivityAtMs: info.lastActivityAtMs,
            activity: info.activity,
            cpuPercent: info.cpuPercent,
            memoryMb: info.memoryMb
        )
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
        state = .starting
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
        applyState(
            alive: info.alive,
            exitCode: info.exitCode,
            lastActivityAtMs: info.lastActivityAtMs,
            activity: info.activity,
            cpuPercent: info.cpuPercent,
            memoryMb: info.memoryMb
        )
        // Build the emulator now that a process exists. Before this there was
        // nothing to draw.
        _ = view
        start()
    }

    private static func makeTerminalView(delegate: TerminalViewDelegate) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // Colour it before SwiftUI's first layout pass, not after.
        //
        // A TUI asks the emulator what its background is (OSC 11) within
        // milliseconds of starting, and SwiftTerm answers from the colour the
        // view is currently carrying. Waiting for `updateNSView` meant the
        // answer could still be the default black while the window was in
        // light mode, and an agent only asks once: it then drew for a dark
        // terminal for the rest of the session.
        applyAppearance(NSApp.effectiveAppearance, to: view)
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
        Self.paint(dark: scheme == .dark, to: view)
    }

    /// The same, from an `NSAppearance`, for the moment before SwiftUI has
    /// had a chance to say what the scheme is.
    private static func applyAppearance(_ appearance: NSAppearance, to view: TerminalView) {
        paint(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, to: view)
    }

    /// Same two surfaces as the rest of the app, so the terminal reads as part
    /// of the pane rather than as a white block in a dark window.
    ///
    /// Setting `nativeBackgroundColor` also sets the emulator's own background,
    /// which is what a program's OSC 11 query is answered from. That is the
    /// only channel a running TUI has for asking, so it has to be right before
    /// the process draws anything.
    private static func paint(dark: Bool, to view: TerminalView) {
        let background: UInt32 = dark ? 0x0A0A0B : 0xF7F7F8
        let foreground: UInt32 = dark ? 0xDCDCE0 : 0x1C1C1F
        view.nativeBackgroundColor = nsColor(background)
        view.nativeForegroundColor = nsColor(foreground)
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
            // Detached, and deliberately so. This class is a MainActor class,
            // so a plain `Task` here runs its body on the main actor: every
            // keystroke would have to be scheduled on the thread that is busy
            // parsing and drawing output before it could even reach the
            // bridge. Under a stream that is seconds of queue, and it is the
            // whole "typing stops working while a build prints" report. The
            // bridge call itself needs no actor, so nothing here touches the
            // main actor on the way to the pty.
            let events = eventStream.stream
            writerTask = Task.detached(priority: .userInitiated) { [weak self] in
                // Held locally so the loop can decide whether the error state
                // changed without reading main-actor state.
                var lastError: String?
                for await event in events {
                    switch event {
                    case let .write(bytes):
                        var failure: String?
                        do {
                            try await Bridge.ptyWrite(id: bridgeID, bytes: bytes)
                        } catch {
                            failure = error.localizedDescription
                        }
                        // The byte has landed, so the echo is on its way. Read
                        // now rather than on whatever the loop's next scheduled
                        // read happened to be: `send` already woke the loop,
                        // but that was before the write crossed the bridge.
                        //
                        // Not awaited. Waiting for the main actor here would
                        // put the next keystroke back behind the draw queue,
                        // which is what this task exists to avoid.
                        Task { @MainActor [weak self] in self?.wake() }
                        if failure != lastError {
                            lastError = failure
                            Task { @MainActor [weak self] in
                                self?.transportError = failure
                            }
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
        idleCheckTask?.cancel()
        idleCheckTask = nil
        state = .none
        pollTask?.cancel()
        pollTask = nil
        // A cancelled task still sitting in a nap would never return from it.
        endNap()
        writerTask?.cancel()
        writerTask = nil
    }

    private func poll(id: String) async {
        while !Task.isCancelled {
            do {
                // The focused session asks the host to hold the call open, so
                // the answer leaves the instant the bytes exist. That is the
                // difference between a terminal and a screen refreshing at some
                // interval: no schedule sits between the echo and the reader.
                //
                // Only the focused one. A held call parks a socket and a host
                // thread, and nobody is waiting on a background session's
                // bytes: those keep their cheap interval poll.
                let chunk = try await Bridge.ptyRead(
                    id: id,
                    offset: offset,
                    waitMs: isFocused ? Self.readHold : 0
                )
                // Guarded. This is observed, and a session the reader cannot
                // keep up with reports a drop on every single poll: an
                // unguarded write there rebuilds the pane at poll rate, on the
                // one thread that is already behind.
                if chunk.dropped > 0, !droppedOutput { droppedOutput = true }
                if !chunk.bytes.isEmpty {
                    await feed(chunk.bytes)
                    offset = chunk.nextOffset
                    // Output is flowing, so stay at the floor: this is where
                    // typing latency comes from.
                    pollDelay = pollFloor
                } else if Date() < hotUntil {
                    // Nothing came back yet, but somebody is typing. Backing
                    // off here is what made the first character after a quiet
                    // moment feel late.
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
            //
            // Counted in real milliseconds rather than in scheduled delay: a
            // held read returns when it returns, so adding the delay that was
            // never waited would stop the liveness check from ever coming due.
            sinceInfo += max(pollDelay, Int(Date().timeIntervalSince(lastLoopAt) * 1000))
            lastLoopAt = Date()
            // Not while somebody is typing: an info call is a second round
            // trip inside the loop that the echo is waiting on. It resumes a
            // fraction of a second after the typing stops.
            if sinceInfo >= 250, Date() >= hotUntil {
                sinceInfo = 0
                if let info = try? await Bridge.ptyInfo(id: id) {
                    // Guarded. These are observed, this runs several times a
                    // second per session, and the values almost never change:
                    // an unguarded write is a sidebar rebuild for nothing.
                    if rows != info.rows { rows = info.rows }
                    if cols != info.cols { cols = info.cols }
                    if alive != info.alive {
                        alive = info.alive
                        if !info.alive {
                            idleCheckTask?.cancel()
                            idleCheckTask = nil
                            state = info.exitCode != nil ? .stopped : .none
                        }
                    }
                    if info.alive {
                        applyActivity(
                            info.activity,
                            cpuPercent: info.cpuPercent,
                            memoryMb: info.memoryMb
                        )
                    }
                    if let code = info.exitCode {
                        exitCode = code
                        idleCheckTask?.cancel()
                        idleCheckTask = nil
                        state = .stopped
                        // One last read in case output arrived right at exit.
                        if let final = try? await Bridge.ptyRead(id: id, offset: offset) {
                            if final.dropped > 0, !droppedOutput { droppedOutput = true }
                            if !final.bytes.isEmpty {
                                offset = final.nextOffset
                                await feed(final.bytes)
                            }
                        }
                        break
                    }
                }
            }

            // The focused session never sleeps between reads. The held call is
            // the pacing: it returns the moment there is output and otherwise
            // costs four round trips a second. Napping on top of it would put
            // back the very interval that holding the call exists to remove,
            // and an idle terminal that had backed off to 400 ms would show the
            // first line of a waking agent that late.
            if !isFocused {
                await nap(pollDelay)
            }
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
    private func feed(_ bytes: Data) async {
        if !hasOutput {
            hasOutput = true
        }
        lastOutputAt = Date()
        // Bytes only decide the state until the host's detector has spoken.
        // After that they are just a clock for "idle for how long".
        // Write only on transition: an unguarded assignment on every packet
        // rebuilds the sidebar at print rate until the host's first verdict.
        if alive, !hostReportedActivity {
            if state != .working {
                state = .working
            }
            // One long-lived timer, not a cancel/recreate per packet.
            ensureIdleCheck()
        }
        // In slices, with a turn of the run loop between them.
        //
        // Parsing is main-thread work and it is not cheap: measured against
        // this emulator, plain lines run about 60 MB/s and a full-screen TUI
        // repaint about 12, so half a megabyte of an agent redrawing itself is
        // ~40 ms of main thread in one uninterruptible block. Feeding a whole
        // poll's worth at once means a keystroke waits out that block, then the
        // next one, for as long as the output lasts. Sliced, the same total
        // work is the same total work, but the run loop gets between the
        // pieces and a key press is handled within a slice rather than within
        // a chunk. The parser is a state machine that already survives a
        // sequence cut in half by a read boundary, so this changes nothing
        // about what is drawn.
        let all = [UInt8](bytes)
        var start = 0
        while start < all.count {
            let end = min(start + Self.feedSlice, all.count)
            view.feed(byteArray: all[start..<end])
            start = end
            if start < all.count { await Task.yield() }
        }
        if TerminalPreferences.exposesToVoiceOver {
            publishAccessibilityValue()
        }
    }

    /// How much output is handed to the emulator between two turns of the run
    /// loop. Around 2 ms of parsing at the worst rate measured, which is under
    /// a display frame and far under anything a person feels as a stuck key.
    private static let feedSlice = 24 * 1024

    /// Set the session state from a host report.
    ///
    /// A process that just started, or whose last output is unknown, reads as
    /// working until the first idle check: the alternative, labelling a
    /// freshly launched agent "Idle" until it prints, is wrong in the
    /// direction that matters. A known activity age flips to idle on adopt
    /// when the session genuinely is quiet.
    private func applyState(
        alive: Bool,
        exitCode: Int?,
        lastActivityAtMs: Int64?,
        activity: String? = nil,
        cpuPercent: Double? = nil,
        memoryMb: Double? = nil
    ) {
        idleCheckTask?.cancel()
        idleCheckTask = nil
        if !alive {
            state = exitCode != nil ? .stopped : .none
            return
        }
        if activity != nil {
            applyActivity(activity, cpuPercent: cpuPercent, memoryMb: memoryMb)
            return
        }
        if let last = lastActivityAtMs {
            let ageMs = Date().timeIntervalSince1970 * 1000 - Double(last)
            state = ageMs <= Self.idleThreshold * 1000 ? .working : .idle
        } else {
            state = .working
        }
        if state == .working {
            ensureIdleCheck()
        }
    }

    /// Take the host's verdict.
    ///
    /// The host measures the process subtree's CPU against a level each
    /// session teaches it, folds in the agent's own lifecycle hooks and its
    /// transcript writes, and answers with one word. That is a far better
    /// answer than this side can compute, so once it arrives the local timer
    /// is cancelled and never runs again for this session.
    private func applyActivity(_ activity: String?, cpuPercent: Double?, memoryMb: Double? = nil) {
        guard let activity else { return }
        hostReportedActivity = true
        idleCheckTask?.cancel()
        idleCheckTask = nil
        // Store what is displayed, not what was measured. These arrive four
        // times a second and never repeat exactly, so writing the raw value
        // rebuilt the sidebar on every poll to redraw the same text. Rounded
        // first, the write happens when the number on screen actually
        // changes, which is the rule the rest of this poll loop follows.
        let cpu = cpuPercent.map { ($0).rounded() }
        let memory = memoryMb.map { ($0).rounded() }
        if self.cpuPercent != cpu { self.cpuPercent = cpu }
        if self.memoryMb != memory { self.memoryMb = memory }
        let next: SessionState = activity == "working" ? .working : .idle
        if state != next { state = next }
    }

    /// Start the working-to-idle timer if one is not already running.
    ///
    /// One task for the session, not a cancel/recreate on every output
    /// packet. The loop re-checks `lastOutputAt` after each wait, so continued
    /// output postpones idle without thrashing the task queue.
    private func ensureIdleCheck() {
        guard idleCheckTask == nil else { return }
        idleCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.alive {
                try? await Task.sleep(for: .seconds(Self.idleThreshold))
                guard !Task.isCancelled, self.alive else { break }
                if let last = self.lastOutputAt,
                   Date().timeIntervalSince(last) < Self.idleThreshold
                {
                    continue
                }
                if self.state == .working {
                    self.state = .idle
                }
                break
            }
            self?.idleCheckTask = nil
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
        // Keep reading fast for a moment. An echo does not come back on the
        // same millisecond as the keystroke: the write crosses the bridge, the
        // process runs, and the reply is buffered on the host. Without this
        // window the read that follows a keystroke comes back empty, the loop
        // doubles its delay, and the character lands a fifth of a second later
        // on a terminal that was idle right before you typed.
        hotUntil = Date().addingTimeInterval(Self.hotWindow)
        // A delay that was already being waited out is the other half of the
        // lag, and setting `pollDelay` does nothing about it. Cut the nap
        // short instead.
        endNap()
    }

    /// While this is in the future the poll stays at its floor, whatever the
    /// reads return.
    private var hotUntil = Date.distantPast
    /// How long typing keeps the read loop fast. Long enough to cover the
    /// bridge round trip and the process, short enough that a session nobody
    /// is typing in goes quiet again immediately.
    private static let hotWindow: TimeInterval = 0.4

    /// The current nap, if the loop is in one. Resumed early by `wake`.
    private var napper: CheckedContinuation<Void, Never>?

    /// Sleep, but wake early when there is a reason to read now.
    ///
    /// `Task.sleep` cannot be cut short, so a keystroke arriving one
    /// millisecond into a 400 millisecond back-off used to wait out all 400 of
    /// them before the echo could even be asked for.
    private func nap(_ milliseconds: Int) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            await self?.endNap()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            napper = continuation
        }
        timer.cancel()
    }

    /// End the current nap, whether the timer ran out or something woke it.
    /// Resumes at most once: a continuation resumed twice is a crash.
    func endNap() {
        guard let continuation = napper else { return }
        napper = nil
        continuation.resume()
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

    /// OSC 0/2. Guarded: a program that puts a progress figure in its title
    /// sets one per redraw, and `title` is observed, so an unguarded write is a
    /// tab strip rebuilt at the rate the program prints.
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            if self.title != title { self.title = title }
        }
    }

    /// OSC 7, and the same reasoning: a shell emits it on every prompt.
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            if reportedCwd != directory { reportedCwd = directory }
        }
    }

    /// The emulator scrolled.
    ///
    /// **Once per line**, from inside the feed, so a build log calls this
    /// thousands of times a second. It used to hop to the main actor with a
    /// `Task` and clear the accessibility throttle, which meant a queue of
    /// main-actor jobs as long as the output, each one rebuilding the visible
    /// screen as text. That queue is what a keystroke had to wait behind, and
    /// it grows for as long as the process prints: the longer the stream, the
    /// further behind typing fell.
    ///
    /// Nothing to do here when the screen is not exposed to VoiceOver, and
    /// when it is, the throttled path already refreshes it four times a second.
    nonisolated func scrolled(source: TerminalView, position: Double) {
        guard TerminalPreferences.exposesToVoiceOver else { return }
        // SwiftTerm calls this on the main thread: from the feed, which runs
        // there, or from a user scroll.
        MainActor.assumeIsolated { publishAccessibilityValue() }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 clipboard write from the program inside the terminal. Denied:
    /// a remote process must not write this Mac's clipboard uninvited.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
}
#endif
