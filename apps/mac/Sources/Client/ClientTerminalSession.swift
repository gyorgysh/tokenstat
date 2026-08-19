// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation
import Observation
import SwiftTerm
import SwiftUI
import UIKit

/// One live terminal on a remote host, driven over the tunnel for the phone.
///
/// Same model as the Mac `TerminalSession` (host owns the process, we poll
/// and type), simplified for a full-screen mobile surface.
@MainActor
@Observable
final class ClientTerminalSession: TerminalViewDelegate, Identifiable {
    let id: String
    let peer: String
    private(set) var hostID: String
    let command: String
    let cwd: String

    private(set) var alive: Bool
    private(set) var exitCode: Int?
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var hasOutput = false
    private(set) var droppedOutput = false
    private(set) var outputPaused = false
    var transportError: String?

    @ObservationIgnored private var terminalView: TerminalView?
    @ObservationIgnored private var offset: UInt64 = 0
    /// Output on its way to the emulator, minus what it cannot read correctly.
    @ObservationIgnored private var outputFilter = TerminalOutputFilter()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var removed = false
    @ObservationIgnored private var isPending = false
    /// Close was tapped before spawn returned. Kill the real id on attach.
    @ObservationIgnored private var closeWhenAttached = false
    @ObservationIgnored private var lastInfoAt = Date.distantPast
    @ObservationIgnored private var inForeground = true

    private enum PtyEvent {
        case write([UInt8])
        case resize(rows: Int, cols: Int)
    }

    nonisolated private let eventStream = AsyncStream<PtyEvent>.makeStream()

    var view: TerminalView {
        if let terminalView { return terminalView }
        let created = Self.makeView(delegate: self)
        terminalView = created
        return created
    }

    init(peer: String, info: PtySessionInfo) {
        id = UUID().uuidString
        self.peer = peer
        hostID = info.id
        command = info.command
        cwd = info.cwd
        alive = info.alive
        exitCode = info.exitCode
        rows = max(info.rows, 24)
        cols = max(info.cols, 80)
        _ = view
        start()
    }

    init(peer: String, pendingCommand: String, cwd: String, rows: Int, cols: Int) {
        id = UUID().uuidString
        self.peer = peer
        hostID = "pending-\(UUID().uuidString)"
        command = pendingCommand
        self.cwd = cwd
        alive = false
        exitCode = nil
        self.rows = rows
        self.cols = cols
        isPending = true
    }

    func attach(info: PtySessionInfo) {
        guard isPending else { return }
        if removed && !closeWhenAttached { return }
        hostID = info.id
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        isPending = false
        if closeWhenAttached || removed {
            let peer = peer
            let id = info.id
            Task { try? await ClientRemote.ptyClose(peer: peer, id: id) }
            endLocalWork()
            return
        }
        _ = view
        start()
    }

    func stop() {
        removed = true
        // The reported bug, from this end: closing a session here used to leave
        // the Mac's own terminal clamped to the phone's width. Giving up the
        // claim puts it straight back. Fire and forget: the host expires the
        // claim on its own, and closing a screen must not wait on the tunnel.
        if !isPending, !hostID.isEmpty {
            let id = hostID
            let peer = peer
            Task.detached { try? await ClientRemote.ptyDetach(peer: peer, id: id) }
        }
        endLocalWork()
    }

    /// Stop the process on the host, then drop the phone's hold.
    ///
    /// Done only detaches. Close is what the Mac tab close does.
    /// Throws when the host never heard the close, so the caller can keep
    /// the row instead of pretending the process is gone.
    func close() async throws {
        if isPending {
            closeWhenAttached = true
            removed = true
            endLocalWork()
            return
        }
        guard !hostID.isEmpty else {
            removed = true
            endLocalWork()
            return
        }
        do {
            try await ClientRemote.ptyClose(peer: peer, id: hostID)
        } catch {
            transportError = error.localizedDescription
            throw error
        }
        removed = true
        endLocalWork()
    }

    private func endLocalWork() {
        pollTask?.cancel()
        pollTask = nil
        writerTask?.cancel()
        writerTask = nil
        eventStream.continuation.finish()
    }

    /// The screen is on screen. Backgrounded polls skip the held read so a
    /// frozen phone does not sit in a tunnel wait, and coming back nudges
    /// the supervisor instead of waiting out a leftover backoff.
    func setForeground(_ active: Bool) {
        inForeground = active
    }

    /// A path change is not a dead process. Drop the last transport error so
    /// the next poll can reattach by pty id over a new dial.
    func clearTransientTunnelError() {
        if let error = transportError, ClientTunnelCopy.isAbsent(error) {
            transportError = nil
        }
    }

    private func start() {
        guard !isPending else { return }
        let bridgeID = hostID
        let peer = peer
        if writerTask == nil {
            let events = eventStream.stream
            writerTask = Task.detached(priority: .userInitiated) { [weak self] in
                var lastError: String?
                for await event in events {
                    switch event {
                    case let .write(bytes):
                        var failure: String?
                        do {
                            try await ClientRemote.ptyWrite(peer: peer, id: bridgeID, bytes: bytes)
                        } catch {
                            failure = error.localizedDescription
                        }
                        if failure != lastError {
                            lastError = failure
                            Task { @MainActor [weak self] in
                                self?.transportError = failure
                            }
                        }
                    case let .resize(rows, cols):
                        try? await ClientRemote.ptyResize(
                            peer: peer,
                            id: bridgeID,
                            rows: rows,
                            cols: cols
                        )
                    }
                }
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.poll(peer: peer, id: bridgeID)
        }
    }

    nonisolated private func poll(peer: String, id: String) async {
        var recoveryDelay = 50
        var failedReads = 0
        while !Task.isCancelled {
            guard let plan = await makePlan() else { break }
            do {
                let chunk = try await ClientRemote.ptyRead(
                    peer: peer,
                    id: id,
                    offset: plan.offset,
                    waitMs: plan.waitMs
                )
                let shouldStop = await apply(chunk)
                if shouldStop { break }
                if plan.checkAlive, !(await checkLiveness(peer: peer, id: id)) { break }
                recoveryDelay = 50
                failedReads = 0
            } catch {
                failedReads += 1
                let retry = await notePollFailure(
                    peer: peer,
                    id: id,
                    error: error,
                    failedReads: failedReads
                )
                if !retry || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(recoveryDelay))
                recoveryDelay = min(recoveryDelay * 2, 2_000)
                continue
            }
            if plan.delay > 0 {
                try? await Task.sleep(for: .milliseconds(plan.delay))
            }
        }
        await MainActor.run { [weak self] in self?.pollTask = nil }
    }

    @MainActor
    private func notePollFailure(
        peer: String,
        id: String,
        error: Error,
        failedReads: Int
    ) async -> Bool {
        guard !removed else { return false }
        let message = error.localizedDescription
        if transportError != message { transportError = message }
        guard failedReads.isMultiple(of: 8) else { return true }
        guard let info = try? await ClientRemote.ptyInfo(peer: peer, id: id) else {
            if failedReads >= 40 {
                do {
                    let sessions = try await ClientRemote.ptyList(peer: peer)
                    if !sessions.contains(where: { $0.id == id }) {
                        alive = false
                        return false
                    }
                } catch {
                    // A failed list is still a transport outage, not proof
                    // that the remote PTY disappeared.
                }
            }
            return true
        }
        if rows != info.rows { rows = info.rows }
        if cols != info.cols { cols = info.cols }
        if alive != info.alive { alive = info.alive }
        if let code = info.exitCode {
            exitCode = code
            return false
        }
        if info.alive { transportError = nil }
        return info.alive
    }

    private struct Plan: Sendable {
        var offset: UInt64
        var waitMs: Int
        var delay: Int
        var checkAlive: Bool
    }

    @MainActor
    private func makePlan() -> Plan? {
        guard !removed else { return nil }
        return Plan(
            offset: offset,
            waitMs: inForeground ? 250 : 0,
            delay: inForeground ? (hasOutput ? 16 : 50) : 2_000,
            checkAlive: inForeground
        )
    }

    @MainActor
    private func apply(_ chunk: PtyChunk) async -> Bool {
        if outputPaused != chunk.paused { outputPaused = chunk.paused }
        if chunk.dropped > 0 { droppedOutput = true }
        if !chunk.bytes.isEmpty {
            offset = chunk.nextOffset
            hasOutput = true
            // Same filter as the Mac pane, for the same reason: this build's
            // SwiftTerm mistakes the kitty keyboard announcement for a cursor
            // restore. See `TerminalOutputFilter`.
            let bytes = outputFilter.filter([UInt8](chunk.bytes)[...])
            let slice = 24 * 1024
            var start = 0
            while start < bytes.count {
                guard !removed else { return true }
                let end = min(start + slice, bytes.count)
                view.feed(byteArray: ArraySlice(bytes[start..<end]))
                start = end
                if start < bytes.count {
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }
        return false
    }

    /// Ask the host whether the process is still running. A clean exit used
    /// to leave this screen saying Running until the next failed read.
    @MainActor
    private func checkLiveness(peer: String, id: String) async -> Bool {
        guard !removed else { return false }
        guard Date().timeIntervalSince(lastInfoAt) >= 0.25 else { return true }
        lastInfoAt = Date()
        guard let info = try? await ClientRemote.ptyInfo(peer: peer, id: id) else {
            return true
        }
        if rows != info.rows { rows = info.rows }
        if cols != info.cols { cols = info.cols }
        if alive != info.alive { alive = info.alive }
        if let code = info.exitCode {
            exitCode = code
            alive = false
            return false
        }
        if !info.alive {
            alive = false
            return false
        }
        transportError = nil
        return true
    }

    private static func makeView(delegate: TerminalViewDelegate) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let background: UInt32 = dark ? 0x0A0A0B : 0xF7F7F8
        let foreground: UInt32 = dark ? 0xDCDCE0 : 0x1C1C1F
        view.nativeBackgroundColor = uiColor(background)
        view.nativeForegroundColor = uiColor(foreground)
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.optionAsMetaKey = true
        view.getTerminal().changeHistorySize(4_000)
        view.terminalDelegate = delegate
        // Soft keyboard: TerminalView is a UIKeyInput scroll view.
        view.isUserInteractionEnabled = true
        // SwiftTerm's own accessory has no Shift and no back-tab, which is the
        // one chord an agent session needs. `ClientTerminalKeys` replaces it,
        // and two bars stacked would be worse than the gap it fills.
        view.inputAccessoryView = nil
        return view
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            guard newCols > 0, newRows > 0 else { return }
            // Against what was last announced, not against `rows`/`cols`. Those
            // are the host's answer, and the host's answer is the *agreed* size
            // across every viewer, which on a phone attached to a wider Mac is
            // smaller than this screen. Comparing against it would suppress the
            // announcement of the phone's real width, and the pty would keep
            // wrapping to a geometry this screen cannot show.
            if announced?.rows == newRows, announced?.cols == newCols { return }
            announced = (rows: newRows, cols: newCols)
            eventStream.continuation.yield(.resize(rows: newRows, cols: newCols))
        }
    }

    /// What this screen last told the host it can show.
    @ObservationIgnored private var announced: (rows: Int, cols: Int)?

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Whether a drag scrolls the buffer instead of reaching the program.
    ///
    /// An agent that asks for mouse reporting gets every drag as an event,
    /// which pins the view to the bottom of a 4,000 line scrollback. Turning
    /// reporting off hands panning back to the terminal. Starts off, because
    /// typing is what a keyboard is for and a scroll is the deliberate act.
    var scrolls: Bool = false {
        didSet {
            guard scrolls != oldValue else { return }
            terminalView?.allowMouseReporting = !scrolls
        }
    }

    /// Put the keyboard away, or bring it back, without ending the session.
    ///
    /// Hiding it is what makes a phone readable, and until the terminal is
    /// tapped there is nothing that says how to get it back. The same key
    /// does both.
    func toggleKeyboard() {
        guard let view = terminalView else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    /// Type raw bytes, for the key bar above the keyboard.
    ///
    /// The same queue typing uses, so a tapped key and a typed one cannot
    /// arrive out of order.
    func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        eventStream.continuation.yield(.write(bytes))
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in
            eventStream.continuation.yield(.write(bytes))
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            Task { @MainActor in
                UIPasteboard.general.string = text
            }
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftUI host for the SwiftTerm iOS view.
struct ClientTerminalRepresentable: UIViewRepresentable {
    let session: ClientTerminalSession

    func makeUIView(context: Context) -> TerminalView {
        let view = session.view
        view.setNeedsDisplay()
        // Become first responder so the software keyboard can type.
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Focus is taken once, on appear. Taking it back on every update
        // would make Hide keyboard last until the next redraw, which on a
        // live terminal is immediately.
        uiView.allowMouseReporting = !session.scrolls
    }
}

/// Full-screen terminal for one remote session.
struct ClientTerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: ClientTerminalSession
    var hostName: String = ""
    var onClose: (() -> Void)?
    var onClosedProcess: (() -> Void)?

    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: session.command).lastPathComponent)
                        .font(ClientType.label.weight(.semibold))
                        .lineLimit(1)
                    Text(session.alive ? session.cwd : (session.exitCode.map { "exited \($0)" } ?? "stopped"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if session.droppedOutput {
                    Text("output dropped")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.warning)
                }
                Button("Close", .dismiss, role: .destructive) {
                    confirmClose = true
                }
                .font(ClientType.caption.weight(.semibold))
                Button("Done", .done) {
                    onClose?()
                    dismiss()
                }
                .font(ClientType.caption.weight(.semibold))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.background)

            if session.outputPaused {
                Text("Output paused while the terminal catches up.")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.xs)
            }

            if let error = session.transportError {
                Text(ClientTunnelCopy.display(error, host: hostName))
                    .font(ClientType.caption)
                    .foregroundStyle(
                        ClientTunnelCopy.isAbsent(error) ? Theme.warning : Theme.danger
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.xs)
            }

            ClientTerminalRepresentable(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A row in the stack, not a `safeAreaInset`. The terminal is a
            // UIKit view that draws across its whole frame and ignores the
            // safe area it is handed, so an inset reserved nothing and the
            // bar covered the last lines of output. Taking the space out of
            // the layout is the only thing the terminal reflows around.
            //
            // Above the keyboard when it is up, above the home indicator when
            // it is not. Either way it is where a thumb already is.
            ClientTerminalKeys(
                send: { session.sendBytes($0) },
                toggleKeyboard: { session.toggleKeyboard() },
                scrolls: Binding(
                    get: { session.scrolls },
                    set: { session.scrolls = $0 }
                )
            )
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear {
            session.setForeground(true)
        }
        .onChange(of: scenePhase) { _, phase in
            session.setForeground(phase == .active)
            if phase == .active {
                Task { await Bridge.nudgeTunnel() }
            }
        }
        .onDisappear {
            // Full-screen dismiss: stop draining when nobody is watching.
            // Re-open attaches a fresh session from pty.list.
            session.stop()
        }
        .confirmationDialog(
            "Close this session?",
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                Task {
                    do {
                        try await session.close()
                        onClosedProcess?()
                        onClose?()
                        dismiss()
                    } catch {
                        // Keep the screen. The process is still running.
                    }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(hostName.isEmpty
                ? "Stops the process on the computer."
                : "Stops the process on \(hostName).")
        }
    }
}

#endif
